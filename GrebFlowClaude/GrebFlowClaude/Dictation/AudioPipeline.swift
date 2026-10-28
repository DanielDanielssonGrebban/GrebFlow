@preconcurrency import AVFoundation
import Foundation
import Speech

/// Receives microphone buffers on the audio queue, copies them, and hands
/// them to a serial conversion queue that feeds a sink: the speech analyzer
/// for Apple's recognizer, or a sample buffer for Whisper.
///
/// Everything here runs off the main actor. UI-facing updates (level, first
/// buffer timing) go back through `Task { @MainActor in ... }` inside the
/// Sendable callbacks supplied by the owner.
final class AudioPipeline: @unchecked Sendable {
    typealias LevelHandler = @Sendable (Float) -> Void
    typealias FirstBufferHandler = @Sendable (UInt64) -> Void

    /// Where converted audio goes. `finish` runs once, after the last buffer.
    struct Sink: Sendable {
        let yield: @Sendable (AVAudioPCMBuffer) -> Void
        let finish: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.grebban.GrebFlowClaude.audio-conversion", qos: .userInitiated)
    private let targetFormat: AVAudioFormat
    private let sink: Sink
    private let onLevel: LevelHandler
    private let onFirstBuffer: FirstBufferHandler

    // Guarded by `lock`.
    private var isClosed = false
    private var sawFirstBuffer = false

    // Only touched on `queue`.
    private var converter: AVAudioConverter?
    private var lastLevelUptime: UInt64 = 0

    private static let levelInterval: UInt64 = 100_000_000 // ~10 updates per second

    init(
        targetFormat: AVAudioFormat,
        sink: Sink,
        onLevel: @escaping LevelHandler,
        onFirstBuffer: @escaping FirstBufferHandler
    ) {
        self.targetFormat = targetFormat
        self.sink = sink
        self.onLevel = onLevel
        self.onFirstBuffer = onFirstBuffer
    }

    convenience init(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping LevelHandler,
        onFirstBuffer: @escaping FirstBufferHandler
    ) {
        self.init(
            targetFormat: targetFormat,
            sink: Sink(
                yield: { continuation.yield(AnalyzerInput(buffer: $0)) },
                finish: { continuation.finish() }
            ),
            onLevel: onLevel,
            onFirstBuffer: onFirstBuffer
        )
    }

    /// Called on the audio queue. Does the minimum: bookkeeping under the
    /// lock and a copy of the borrowed buffer.
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        let isFirst = !sawFirstBuffer
        sawFirstBuffer = true
        lock.unlock()

        if isFirst { onFirstBuffer(DispatchTime.now().uptimeNanoseconds) }
        guard let copy = buffer.deepCopy() else { return }
        queue.async { [self] in process(copy) }
    }

    /// Stops accepting input. Buffers already queued are still converted and
    /// handed to the sink before it finishes.
    func close() async {
        lock.withLock { isClosed = true }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                flushConverter()
                sink.finish()
                done.resume()
            }
        }
    }

    /// Sample-rate conversion holds back a few milliseconds of audio. Drain
    /// it at the end so the last word of a recording isn't clipped.
    private func flushConverter() {
        guard let converter else { return }
        self.converter = nil
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return }
        sink.yield(output)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        publishLevel(for: buffer)
        guard let converted = convert(buffer) else { return }
        sink.yield(converted)
    }

    private func publishLevel(for buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLevelUptime >= Self.levelInterval else { return }
        lastLevelUptime = now
        onLevel(buffer.normalizedLevel)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

enum AudioTapFactory {
    /// Builds the exact callback passed to `installTap`. It is explicitly
    /// nonisolated and Sendable so it never inherits main-actor isolation
    /// from the caller, and it captures only the thread-safe pipeline.
    nonisolated static func makeTap(for pipeline: AudioPipeline) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            pipeline.receive(buffer)
        }
    }
}

extension AVAudioPCMBuffer {
    /// The tap's buffer is only valid during the callback, so copy it before
    /// it leaves the audio queue.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Rough 0...1 loudness for the menu bar icon, based on RMS in dBFS.
    var normalizedLevel: Float {
        guard let channels = floatChannelData, frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(frameLength))
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(frameLength)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
