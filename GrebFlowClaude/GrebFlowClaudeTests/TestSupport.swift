import ApplicationServices
import CoreGraphics
import Foundation
@testable import GrebFlowClaude

/// Small thread-safe box for values written from background queues.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
final class FakeEngine: DictationEngine {
    var isPrepared = true
    var onInterruption: (@MainActor (String) -> Void)?

    var transcript = "hello world"
    var startError: Error?
    var holdStart = false
    var holdFinish = false

    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private var startGate: CheckedContinuation<Void, Never>?
    private var finishGate: CheckedContinuation<Void, Never>?

    var isWaitingInStart: Bool { startGate != nil }
    var isWaitingInFinish: Bool { finishGate != nil }

    func prepare() async throws {}

    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws {
        startCount += 1
        if holdStart {
            await withCheckedContinuation { startGate = $0 }
        }
        if let startError { throw startError }
        onLevel(0.5)
    }

    func releaseStart() {
        startGate?.resume()
        startGate = nil
    }

    func finish() async throws -> String {
        finishCount += 1
        if holdFinish {
            await withCheckedContinuation { finishGate = $0 }
        }
        return transcript
    }

    func releaseFinish() {
        finishGate?.resume()
        finishGate = nil
    }

    func cancel() async {
        cancelCount += 1
    }
}

@MainActor
final class FakeInserter: TextInserting {
    var isSecureInputActive = false
    var result: PasteResult = .pasteAttempted
    private(set) var inserted: [String] = []

    func captureDestination() -> PasteDestination {
        PasteDestination(processID: 42, bundleID: "com.example.Terminal", focusedElement: nil)
    }

    func insert(_ text: String, into destination: PasteDestination, shortcut: DictationShortcut) async -> PasteResult {
        inserted.append(text)
        return result
    }
}

@MainActor
final class FakePermissions: PermissionProviding {
    var microphone: MicrophoneAuthorization = .notDetermined
    var grantOnRequest = true
    var listen = true
    var post = true
    var trusted = true
    private(set) var microphoneRequests = 0
    private(set) var listenRequests = 0
    private(set) var accessibilityPrompts = 0

    func microphoneStatus() -> MicrophoneAuthorization { microphone }

    func requestMicrophone() async -> Bool {
        microphoneRequests += 1
        microphone = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }

    private(set) var openedPanes: [PrivacyPane] = []
    var listenGrantedOnRequest = false

    func listenAccess() -> ListenAccess { listen ? .granted : .notDetermined }

    func requestListenAccess() -> Bool {
        listenRequests += 1
        if listenGrantedOnRequest { listen = true }
        return listen
    }

    func openPrivacyPane(_ pane: PrivacyPane) { openedPanes.append(pane) }
    func canPostEvents() -> Bool { post }
    func requestPostAccess() {}
    func isAccessibilityTrusted() -> Bool { trusted }
    func promptAccessibility() { accessibilityPrompts += 1 }
}

@MainActor
final class FakeSpeechAssets: SpeechAssetProviding {
    var state: SpeechAssetState = .installed
    private(set) var installs = 0

    func status() async -> SpeechAssetState { state }

    func install(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        installs += 1
        progress(1)
        state = .installed
    }
}

@MainActor
final class FakePasteEnvironment: PasteEnvironment {
    var isSecureInputActive = false
    var canPostEvents = true
    var frontmostPID: pid_t = 42
    /// Returned in order by successive reads; the last value repeats.
    var flagSequence: [CGEventFlags] = [[]]
    var anotherAppWritesAfterUs = false
    private(set) var flagReads = 0
    private(set) var clipboard: String?
    private(set) var changeCount = 0
    private(set) var postedEvents: [CGEvent] = []

    func physicalModifierFlags() -> CGEventFlags {
        defer { flagReads += 1 }
        return flagSequence[min(flagReads, flagSequence.count - 1)]
    }

    func frontmostApplication() -> (processID: pid_t, bundleID: String?)? { (frontmostPID, "com.example.Terminal") }
    func focusedElement() -> AXUIElement? { nil }

    func writeClipboard(_ text: String) -> Int {
        clipboard = text
        changeCount += 1
        let written = changeCount
        if anotherAppWritesAfterUs { changeCount += 1 }
        return written
    }

    func clipboardChangeCount() -> Int { changeCount }
    func post(_ events: [CGEvent]) { postedEvents += events }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let box: LockedBox<String?>

    init(_ secret: String? = nil) { box = LockedBox(secret) }

    func read() throws -> String? { box.value }
    func save(_ secret: String) throws { box.value = secret }
    func delete() throws { box.value = nil }
}

/// Routes requests from one URLSession to one handler, so tests running in
/// parallel don't see each other's responses.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
        var delay: TimeInterval = 0
    }

    typealias Handler = @Sendable (URLRequest, Data?) throws -> Response

    private static let handlers = LockedBox<[String: Handler]>([:])
    private let stopped = LockedBox(false)

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.mutate { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Session": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Test-Session"),
              let handler = Self.handlers.value[id]
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let response = try handler(request, Self.body(of: request))
            let deliver: @Sendable () -> Void = { [self] in
                guard !stopped.value else { return }
                let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            if response.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: deliver)
            } else {
                deliver()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        stopped.value = true
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func transcript(_ text: String, at date: Date, words: Int? = nil, duration: Double = 3) -> TranscriptDraft {
    TranscriptDraft(
        startedAt: date,
        endedAt: date.addingTimeInterval(duration),
        durationSeconds: duration,
        locale: "en-US",
        text: text,
        insertionText: nil,
        wordCount: words ?? WordCounter.count(text),
        destinationBundleID: nil,
        releaseToFinalSeconds: nil,
        releaseToPasteSeconds: nil,
        outcome: .pasteAttempted
    )
}
