@preconcurrency import AVFoundation
import Foundation

enum CaptureError: LocalizedError {
    case noInputDevice
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone input is available."
        case let .engineFailed(reason): "The microphone could not start: \(reason)"
        }
    }
}

/// Owns AVAudioEngine for one recording at a time. A fresh engine per
/// session avoids carrying stale device configuration between recordings.
/// Nothing is written to disk.
@MainActor
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    /// Called on the main actor when the audio route or device changes while
    /// capturing. The owner decides what to do with the session.
    var onConfigurationChange: (@MainActor () -> Void)?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }

        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.onConfigurationChange?()
            }
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
