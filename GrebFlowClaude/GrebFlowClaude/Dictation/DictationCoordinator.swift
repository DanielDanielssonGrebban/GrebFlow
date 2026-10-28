import Foundation
import Observation
import os

enum DictationPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case finalizing
}

/// What gets saved after a successful, nonempty session.
struct TranscriptDraft: Sendable, Equatable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Double
    var locale: String
    var text: String
    var insertionText: String?
    var wordCount: Int
    var destinationBundleID: String?
    var releaseToFinalSeconds: Double?
    var releaseToPasteSeconds: Double?
    var outcome: PasteOutcome
}

struct SessionTimings: Equatable, Sendable {
    var releaseToFinal: Double
    var releaseToPaste: Double
}

/// Owns every recording session: start, release, cancel, finalize, paste.
///
/// Each session has a unique ID. Anything that finishes after its session
/// was cancelled or replaced is dropped, so stale text is never pasted.
@MainActor
@Observable
final class DictationCoordinator {
    private(set) var phase: DictationPhase = .idle
    private(set) var level: Float = 0
    private(set) var notice: String?
    private(set) var latestTranscript: String?
    private(set) var lastTimings: SessionTimings?

    @ObservationIgnored var isReady: () -> Bool = { true }
    @ObservationIgnored var setupProblem: () -> String? = { nil }
    @ObservationIgnored var shortcut: () -> DictationShortcut = { .rightOption }
    @ObservationIgnored var isShortcutPhysicallyHeld: () -> Bool = { true }
    @ObservationIgnored var onTranscript: (TranscriptDraft) -> Void = { _ in }
    @ObservationIgnored var onMissedRelease: () -> Void = {}
    @ObservationIgnored var watchdogDuration: Duration = .seconds(300)
    @ObservationIgnored var releasePollInterval: Duration = .milliseconds(150)

    @ObservationIgnored private let engine: DictationEngine
    @ObservationIgnored private let inserter: TextInserting
    @ObservationIgnored private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "dictation")
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var releasePoll: Task<Void, Never>?

    private struct Session {
        let id = UUID()
        let startedAt = Date()
        let startUptime = DispatchTime.now().uptimeNanoseconds
        let destination: PasteDestination
        var releaseRequested = false
        var discarded = false
        var releaseUptime: UInt64?
    }

    init(engine: DictationEngine, inserter: TextInserting) {
        self.engine = engine
        self.inserter = inserter
        engine.onInterruption = { [weak self] reason in
            self?.abort(reason: reason)
        }
    }

    var isActive: Bool { phase != .idle }

    /// Starting or recording. Escape is only claimed in this window.
    var isRecording: Bool { phase == .starting || phase == .recording }

    func handle(_ action: ShortcutAction) {
        switch action {
        case .pressed:
            shortcutPressed()
        case .released:
            shortcutReleased()
        case .escape:
            if isRecording { cancel(notice: "Dictation cancelled.") }
        case .otherKeyWhileHeld:
            if phase == .starting || phase == .recording {
                cancel(notice: "Cancelled because another key was pressed with the shortcut.")
            }
        case .ignore:
            break
        }
    }

    func shortcutPressed() {
        // No overlapping sessions. A press while finalizing is ignored.
        guard phase == .idle else { return }
        guard isReady() else {
            notice = setupProblem() ?? "Finish setup in Settings before dictating."
            return
        }
        guard !inserter.isSecureInputActive else {
            notice = PasteSkipReason.secureInput.message
            return
        }

        let session = Session(destination: inserter.captureDestination())
        self.session = session
        phase = .starting
        notice = nil
        level = 0
        Task { await beginCapture(session.id) }
    }

    func shortcutReleased() {
        guard var current = session else { return }
        switch phase {
        case .starting:
            // Remember the release so a slow start can't leave the mic on.
            current.releaseRequested = true
            session = current
        case .recording:
            let id = current.id
            Task { await finish(id, autoPaste: true) }
        case .idle, .finalizing:
            break
        }
    }

    /// Escape, interruptions, and errors. Discards text and audio without
    /// touching the clipboard or history.
    func cancel(notice: String?) {
        guard var current = session else { return }
        switch phase {
        case .starting, .finalizing:
            current.discarded = true
            session = current
        case .recording:
            session = nil
            stopTimers()
            phase = .finalizing
            level = 0
            Task {
                await engine.cancel()
                if session == nil { phase = .idle }
            }
        case .idle:
            break
        }
        if let notice { self.notice = notice }
    }

    func abort(reason: String) {
        logger.notice("Session aborted")
        cancel(notice: reason)
    }

    func clearLatestTranscript() {
        latestTranscript = nil
    }

    private func beginCapture(_ id: UUID) async {
        do {
            try await engine.start { [weak self] level in
                self?.receiveLevel(level, for: id)
            }
        } catch {
            guard session?.id == id else { return }
            session = nil
            phase = .idle
            notice = "Couldn't start recording: \(error.localizedDescription)"
            logger.error("Recording failed to start")
            return
        }

        guard let current = session, current.id == id, !current.discarded else {
            await engine.cancel()
            if session?.id == id { session = nil }
            phase = .idle
            return
        }

        phase = .recording
        startTimers(for: id)
        if current.releaseRequested {
            await finish(id, autoPaste: true)
        }
    }

    private func finish(_ id: UUID, autoPaste: Bool) async {
        guard var current = session, current.id == id, phase == .recording else { return }
        phase = .finalizing
        level = 0
        stopTimers()
        let releaseUptime = DispatchTime.now().uptimeNanoseconds
        current.releaseUptime = releaseUptime
        session = current
        let endedAt = Date()

        let recognized: String
        do {
            recognized = try await engine.finish()
        } catch {
            if session?.id == id { session = nil }
            phase = .idle
            notice = "Recognition failed: \(error.localizedDescription)"
            logger.error("Recognition failed during finalization")
            return
        }

        guard let latest = session, latest.id == id, !latest.discarded else {
            if session?.id == id { session = nil }
            phase = .idle
            return
        }

        let finalUptime = DispatchTime.now().uptimeNanoseconds
        let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let insertion = PasteNormalizer.insertionText(for: text) else {
            session = nil
            phase = .idle
            notice = "No speech was recognized."
            return
        }

        latestTranscript = insertion
        let result = autoPaste
            ? await inserter.insert(insertion, into: latest.destination, shortcut: shortcut())
            : .copyOnly(.watchdog)
        let pasteUptime = DispatchTime.now().uptimeNanoseconds

        if case let .copyOnly(reason) = result { notice = reason.message }

        let releaseToFinal = Self.seconds(from: releaseUptime, to: finalUptime)
        let releaseToPaste = Self.seconds(from: releaseUptime, to: pasteUptime)
        lastTimings = SessionTimings(releaseToFinal: releaseToFinal, releaseToPaste: releaseToPaste)
        logger.info("Session done. release→final \(releaseToFinal, format: .fixed(precision: 3))s, release→paste \(releaseToPaste, format: .fixed(precision: 3))s, outcome \(result.outcome.rawValue, privacy: .public)")

        onTranscript(TranscriptDraft(
            startedAt: latest.startedAt,
            endedAt: endedAt,
            durationSeconds: Self.seconds(from: latest.startUptime, to: releaseUptime),
            locale: SpeechConfig.locale.identifier,
            text: text,
            insertionText: insertion,
            wordCount: WordCounter.count(text),
            destinationBundleID: latest.destination.bundleID,
            releaseToFinalSeconds: releaseToFinal,
            releaseToPasteSeconds: releaseToPaste,
            outcome: result.outcome
        ))

        session = nil
        phase = .idle
    }

    private func receiveLevel(_ value: Float, for id: UUID) {
        guard session?.id == id, phase == .recording else { return }
        level = value
    }

    private func startTimers(for id: UUID) {
        let watchdogDuration = watchdogDuration
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: watchdogDuration)
            guard !Task.isCancelled, let self else { return }
            // Release was probably lost. Keep the text for manual copy only.
            await self.finish(id, autoPaste: false)
        }

        let interval = releasePollInterval
        releasePoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard self.session?.id == id, self.phase == .recording else { return }
                if !self.isShortcutPhysicallyHeld() {
                    self.logger.notice("Shortcut release was missed; finishing from hardware state")
                    self.onMissedRelease()
                    self.shortcutReleased()
                    return
                }
            }
        }
    }

    private func stopTimers() {
        watchdog?.cancel()
        watchdog = nil
        releasePoll?.cancel()
        releasePoll = nil
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end &- start) / 1_000_000_000
    }
}
