@preconcurrency import AVFoundation
import Foundation
import os
import Speech

/// The recording engine the coordinator drives. One session at a time:
/// `start`, then exactly one of `finish` or `cancel`.
@MainActor
protocol DictationEngine: AnyObject {
    var isPrepared: Bool { get }
    var onInterruption: (@MainActor (String) -> Void)? { get set }
    func prepare() async throws
    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws
    func finish() async throws -> String
    func cancel() async
}

enum SpeechEngineError: LocalizedError {
    case unsupportedLocale
    case noCompatibleFormat
    case notRecording

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "English (US) speech recognition isn't supported on this Mac."
        case .noCompatibleFormat: "The speech model didn't report a usable audio format."
        case .notRecording: "No recording is in progress."
        }
    }
}

/// DictationTranscriber rather than SpeechTranscriber because only the
/// dictation module takes contextual strings and a custom language model,
/// which carry the developer vocabulary. Unlike SpeechTranscriber it needs punctuation asked for.
/// Emoji and etiquette replacements stay off so "smiley face" and swear
/// words paste as spoken.
enum SpeechConfig {
    static let locale = Locale(identifier: "en-US")

    static func makeTranscriber(
        locale: Locale,
        languageModel: DeveloperLanguageModel.Files? = nil
    ) -> DictationTranscriber {
        var hints: Set<DictationTranscriber.ContentHint> = []
        if let languageModel {
            hints.insert(.customizedLanguage(modelConfiguration: languageModel.configuration))
        }
        return DictationTranscriber(
            locale: locale,
            contentHints: hints,
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func makeContext() -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = DeveloperVocabulary.terms
        return context
    }

    static func resolvedLocale() async -> Locale? {
        await DictationTranscriber.supportedLocale(equivalentTo: locale)
    }
}

/// Microphone capture plus SpeechAnalyzer/DictationTranscriber.
///
/// An analyzer is prepared ahead of time with `prepareToAnalyze` so pressing
/// the shortcut doesn't pay for model loading. A finalized analyzer can't take
/// another recording, so a new one is prepared after every session.
@MainActor
final class LiveDictationEngine: DictationEngine {
    private struct Prepared {
        let analyzer: SpeechAnalyzer
        let transcriber: DictationTranscriber
        let format: AVAudioFormat
    }

    private struct Active {
        let prepared: Prepared
        let pipeline: AudioPipeline
        let results: Task<String, Error>
    }

    private let capture = MicrophoneCapture()
    private let languageModels = DeveloperLanguageModelStore()
    private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "speech")
    private var prepared: Prepared?
    private var preparing: Task<Prepared, Error>?
    private var active: Active?

    var onInterruption: (@MainActor (String) -> Void)?
    private(set) var firstBufferUptime: UInt64?

    var isPrepared: Bool { prepared != nil }

    init() {
        capture.onConfigurationChange = { [weak self] in
            guard let self, self.active != nil else { return }
            self.onInterruption?("The audio device changed during recording.")
        }
    }

    func prepare() async throws {
        _ = try await preparedAnalyzer()
    }

    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws {
        let prepared = try await preparedAnalyzer()
        // Take ownership; a finalized analyzer can't be used twice.
        if self.prepared?.analyzer === prepared.analyzer { self.prepared = nil }
        firstBufferUptime = nil

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let transcriber = prepared.transcriber
        let results = Task<String, Error> {
            var assembler = TranscriptAssembler()
            for try await result in transcriber.results {
                assembler.apply(TranscriptSegment(
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                ))
            }
            return assembler.finalText
        }

        let pipeline = AudioPipeline(
            targetFormat: prepared.format,
            continuation: continuation,
            onLevel: { level in
                Task { @MainActor in onLevel(level) }
            },
            onFirstBuffer: { uptime in
                Task { @MainActor [weak self] in self?.firstBufferUptime = uptime }
            }
        )

        do {
            try await prepared.analyzer.start(inputSequence: stream)
            try capture.start(tap: AudioTapFactory.makeTap(for: pipeline))
        } catch {
            capture.stop()
            await pipeline.close()
            results.cancel()
            await prepared.analyzer.cancelAndFinishNow()
            prepareNext()
            throw error
        }
        active = Active(prepared: prepared, pipeline: pipeline, results: results)
    }

    func finish() async throws -> String {
        guard let active else { throw SpeechEngineError.notRecording }
        self.active = nil
        defer { prepareNext() }

        // Stop new microphone input, then let already captured buffers drain
        // into the analyzer before the input sequence ends.
        capture.stop()
        await active.pipeline.close()
        do {
            try await active.prepared.analyzer.finalizeAndFinishThroughEndOfInput()
            return try await active.results.value
        } catch {
            active.results.cancel()
            await active.prepared.analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func cancel() async {
        guard let active else { return }
        self.active = nil
        capture.stop()
        await active.pipeline.close()
        active.results.cancel()
        await active.prepared.analyzer.cancelAndFinishNow()
        prepareNext()
    }

    private func prepareNext() {
        Task { [weak self] in
            do {
                try await self?.prepare()
            } catch {
                self?.logger.error("Analyzer preparation failed")
            }
        }
    }

    /// The preparation task stores its result itself, on the main actor,
    /// before any waiter resumes. That way `start` can take ownership of the
    /// analyzer without another waiter putting it back afterwards.
    private func preparedAnalyzer() async throws -> Prepared {
        if let prepared { return prepared }
        let task = preparing ?? Task<Prepared, Error> { [weak self, languageModels] in
            do {
                let result = try await Self.makePrepared(languageModels: languageModels)
                self?.prepared = result
                self?.preparing = nil
                return result
            } catch {
                self?.preparing = nil
                throw error
            }
        }
        preparing = task
        return try await task.value
    }

    private static func makePrepared(languageModels: DeveloperLanguageModelStore) async throws -> Prepared {
        guard let locale = await SpeechConfig.resolvedLocale() else { throw SpeechEngineError.unsupportedLocale }
        let languageModel = await languageModels.files(locale: locale)
        let transcriber = SpeechConfig.makeTranscriber(locale: locale, languageModel: languageModel)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noCompatibleFormat
        }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.setContext(SpeechConfig.makeContext())
        try await analyzer.prepareToAnalyze(in: format)
        return Prepared(analyzer: analyzer, transcriber: transcriber, format: format)
    }
}

enum SpeechAssetState: Equatable, Sendable {
    case unknown
    case unsupported
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .unsupported: "English (US) isn't supported on this Mac"
        case .notInstalled: "Not downloaded"
        case let .downloading(fraction): "Downloading… \(Int(fraction * 100))%"
        case .installed: "Installed"
        case let .failed(reason): "Download failed: \(reason)"
        }
    }
}

@MainActor
protocol SpeechAssetProviding: AnyObject {
    /// Shown in setup messages, like "English speech model not downloaded".
    var modelName: String { get }
    /// Shown while the recognizer loads.
    var preparingMessage: String { get }
    func status() async -> SpeechAssetState
    func install(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws
}

extension SpeechAssetProviding {
    var modelName: String { "English speech model" }
    var preparingMessage: String { "Preparing recognizer" }
}

/// Checks and downloads the on-device English model through AssetInventory.
@MainActor
final class SpeechAssets: SpeechAssetProviding {
    func status() async -> SpeechAssetState {
        guard let locale = await SpeechConfig.resolvedLocale() else { return .unsupported }
        let transcriber = SpeechConfig.makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: return .unsupported
        case .supported: return .notInstalled
        case .downloading: return .downloading(0)
        case .installed: return .installed
        @unknown default: return .unknown
        }
    }

    func install(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard let locale = await SpeechConfig.resolvedLocale() else { throw SpeechEngineError.unsupportedLocale }
        let transcriber = SpeechConfig.makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = request.progress.observe(\.fractionCompleted) { reported, _ in
                let fraction = reported.fractionCompleted
                Task { @MainActor in progress(fraction) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }
}
