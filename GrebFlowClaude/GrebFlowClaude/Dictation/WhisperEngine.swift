@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import WhisperKit

/// Push-to-talk with Whisper: record while the key is held, transcribe the
/// whole clip on release. Whisper isn't a streaming recognizer, so there is
/// no live text, but it tells JSON from Jason by context where Apple's
/// recognizer didn't.
@MainActor
final class WhisperDictationEngine: DictationEngine, UnloadableEngine {
    private struct Active {
        let pipeline: AudioPipeline
        let recorder: SampleRecorder
    }

    private let capture = MicrophoneCapture()
    private let runner = WhisperRunner()
    private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "whisper")
    private var active: Active?
    private var loading: Task<Void, Error>?

    var onInterruption: (@MainActor (String) -> Void)?
    private(set) var isPrepared = false

    init() {
        capture.onConfigurationChange = { [weak self] in
            guard let self, self.active != nil else { return }
            self.onInterruption?("The audio device changed during recording.")
        }
    }

    /// Loads the model once. Later calls wait for the same load.
    func prepare() async throws {
        if isPrepared { return }
        let task = loading ?? Task { [runner] in
            let folder = try WhisperModel.folder()
            guard WhisperModel.isInstalled(at: folder) else { throw WhisperEngineError.modelMissing }
            try await runner.load(modelFolder: folder, prompt: WhisperPrompt.text)
        }
        loading = task
        do {
            try await task.value
            isPrepared = true
        } catch {
            loading = nil
            throw error
        }
    }

    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) async throws {
        try await prepare()
        let recorder = SampleRecorder()
        let pipeline = AudioPipeline(
            targetFormat: WhisperRunner.audioFormat,
            sink: AudioPipeline.Sink(yield: { recorder.append($0) }, finish: {}),
            onLevel: { level in
                Task { @MainActor in onLevel(level) }
            },
            onFirstBuffer: { _ in }
        )
        do {
            try capture.start(tap: AudioTapFactory.makeTap(for: pipeline))
        } catch {
            capture.stop()
            await pipeline.close()
            throw error
        }
        active = Active(pipeline: pipeline, recorder: recorder)
    }

    func finish() async throws -> String {
        guard let active else { throw SpeechEngineError.notRecording }
        self.active = nil
        capture.stop()
        await active.pipeline.close()
        let samples = active.recorder.samples
        guard WhisperAudioGate.isWorthTranscribing(samples, sampleRate: WhisperRunner.audioFormat.sampleRate) else {
            return ""
        }
        let started = ContinuousClock.now
        let text = try await runner.transcribe(samples)
        logger.info("Transcribed \(samples.count / 16_000, privacy: .public) s of audio in \(started.duration(to: .now), privacy: .public)")
        return text
    }

    func cancel() async {
        guard let active else { return }
        self.active = nil
        capture.stop()
        await active.pipeline.close()
    }

    func unload() async {
        loading?.cancel()
        loading = nil
        isPrepared = false
        await runner.unload()
    }
}

enum WhisperEngineError: LocalizedError {
    case modelMissing
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .modelMissing: "The Whisper model isn't downloaded yet."
        case .notLoaded: "The Whisper model isn't loaded."
        }
    }
}

/// Words Whisper doesn't know on its own. Our tests showed that listing
/// JSON here made it write "Ask JSON to review", and listing Jason made it
/// write "check the Jason". Whisper gets both right from context, so they
/// stay off this list.
enum WhisperPrompt {
    static let terms = ["GrebFlow", "npm", "TypeScript", "Xcode"]
    static var text: String { terms.joined(separator: ", ") + "." }
}

/// Whisper invents text for silence ("Thank you.", "[BLANK_AUDIO]"), so
/// very short or near-silent clips are skipped and bracketed markers are
/// dropped.
enum WhisperAudioGate {
    static let minimumSeconds = 0.3
    /// RMS below this is treated as silence. About -50 dBFS.
    static let silenceRMS: Float = 0.003

    static func isWorthTranscribing(_ samples: [Float], sampleRate: Double) -> Bool {
        guard Double(samples.count) >= minimumSeconds * sampleRate else { return false }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot() >= silenceRMS
    }

    /// Square brackets never come from speech, so they go anywhere. Round
    /// ones only when they are the whole output, like "(silence)", since a
    /// dictated "(optional)" is real text.
    static func clean(_ text: String) -> String {
        let collapsed = text.replacing(/\[[^\]]*\]/, with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if collapsed.wholeMatch(of: /\([^)]*\)/) != nil { return "" }
        return collapsed
    }
}

/// Owns the WhisperKit instance. WhisperKit isn't Sendable, so it only
/// ever lives inside this actor.
actor WhisperRunner {
    static let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var whisper: WhisperKit?
    private var promptTokens: [Int]?
    /// Bumped by `unload`, so a load that finishes afterwards is thrown away.
    private var generation = 0

    func load(modelFolder: URL, prompt: String) async throws {
        guard whisper == nil else { return }
        let generation = self.generation
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        guard generation == self.generation else { throw CancellationError() }
        if let tokenizer = whisper.tokenizer {
            promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        self.whisper = whisper
        // The first transcription after loading is slow. Pay for it now
        // instead of on the user's first dictation.
        _ = try? await whisper.transcribe(audioArray: [Float](repeating: 0, count: 16_000), decodeOptions: options())
    }

    func unload() {
        generation += 1
        whisper = nil
        promptTokens = nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisper else { throw WhisperEngineError.notLoaded }
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options())
        return WhisperAudioGate.clean(results.map(\.text).joined(separator: " "))
    }

    private func options() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens
        )
    }
}

/// Collects converted 16 kHz samples from the audio conversion queue.
final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { storage.append(contentsOf: chunk) }
    }

    var samples: [Float] { lock.withLock { storage } }
}
