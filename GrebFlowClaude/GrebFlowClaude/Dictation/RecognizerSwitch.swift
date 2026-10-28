import Foundation

/// Lets Settings switch recognizers without a relaunch. The coordinator and
/// setup controller talk to these wrappers, which forward to whichever
/// recognizer is selected.
///
/// A session keeps the engine it started with, so switching mid-recording
/// can't send `finish` to an engine that never started.
@MainActor
final class SwitchingEngine: DictationEngine {
    private let engines: [Recognizer: DictationEngine]
    private(set) var selected: Recognizer
    private var sessionEngine: DictationEngine?

    var onInterruption: (@MainActor (String) -> Void)? {
        didSet {
            for engine in engines.values { engine.onInterruption = onInterruption }
        }
    }

    init(engines: [Recognizer: DictationEngine], selected: Recognizer) {
        self.engines = engines
        self.selected = selected
    }

    private var current: DictationEngine { engines[selected]! }

    var isPrepared: Bool { current.isPrepared }

    func select(_ recognizer: Recognizer) async {
        guard recognizer != selected else { return }
        let previous = current
        selected = recognizer
        // Whisper holds the model in memory. Nobody else needs it now.
        if let unloadable = previous as? UnloadableEngine, sessionEngine !== previous {
            await unloadable.unload()
        }
    }

    func prepare() async throws {
        try await current.prepare()
    }

    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws {
        let engine = current
        sessionEngine = engine
        do {
            try await engine.start(onLevel: onLevel)
        } catch {
            sessionEngine = nil
            throw error
        }
    }

    func finish() async throws -> String {
        guard let engine = sessionEngine else { throw SpeechEngineError.notRecording }
        sessionEngine = nil
        return try await engine.finish()
    }

    func cancel() async {
        guard let engine = sessionEngine else { return }
        sessionEngine = nil
        await engine.cancel()
    }
}

/// An engine that can drop its loaded model to free memory.
@MainActor
protocol UnloadableEngine: AnyObject {
    func unload() async
}

@MainActor
final class SwitchingAssets: SpeechAssetProviding {
    private let assets: [Recognizer: SpeechAssetProviding]
    private let selected: @MainActor () -> Recognizer

    init(assets: [Recognizer: SpeechAssetProviding], selected: @escaping @MainActor () -> Recognizer) {
        self.assets = assets
        self.selected = selected
    }

    private var current: SpeechAssetProviding { assets[selected()]! }

    var modelName: String { current.modelName }
    var preparingMessage: String { current.preparingMessage }

    func status() async -> SpeechAssetState { await current.status() }

    func install(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        try await current.install(progress: progress)
    }
}
