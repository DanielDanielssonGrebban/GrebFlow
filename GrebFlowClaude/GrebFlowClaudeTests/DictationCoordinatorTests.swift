import Foundation
import Testing
@testable import GrebFlowClaude

@MainActor
@Suite("Dictation sessions")
struct DictationCoordinatorTests {
    let engine = FakeEngine()
    let inserter = FakeInserter()
    let coordinator: DictationCoordinator
    let drafts = LockedBox<[TranscriptDraft]>([])

    init() {
        coordinator = DictationCoordinator(engine: engine, inserter: inserter)
        let drafts = drafts
        coordinator.onTranscript = { draft in drafts.mutate { $0.append(draft) } }
    }

    private func record() async {
        coordinator.handle(.pressed)
        #expect(await waitUntil { coordinator.phase == .recording })
    }

    @Test func holdReleasePastesOnceAndSaves() async {
        await record()
        coordinator.handle(.released)
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted == ["hello world "])
        #expect(drafts.value.count == 1)
        #expect(drafts.value.first?.outcome == .pasteAttempted)
        #expect(drafts.value.first?.destinationBundleID == "com.example.Terminal")
        #expect(coordinator.latestTranscript == "hello world ")
    }

    @Test func fiveConsecutiveSessionsEachPasteOnce() async {
        for index in 0..<5 {
            engine.transcript = "dictation \(index)"
            await record()
            coordinator.handle(.released)
            #expect(await waitUntil { coordinator.phase == .idle })
        }
        #expect(inserter.inserted == (0..<5).map { "dictation \($0) " })
        #expect(engine.startCount == 5)
        #expect(engine.finishCount == 5)
    }

    @Test func releaseDuringStartupStillFinishes() async {
        engine.holdStart = true
        coordinator.handle(.pressed)
        #expect(await waitUntil { engine.isWaitingInStart })
        coordinator.handle(.released)
        #expect(coordinator.phase == .starting)
        engine.releaseStart()
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(engine.finishCount == 1)
        #expect(engine.cancelCount == 0)
        #expect(inserter.inserted == ["hello world "])
    }

    @Test func doubleReleaseFinishesOnce() async {
        await record()
        coordinator.handle(.released)
        coordinator.handle(.released)
        #expect(await waitUntil { coordinator.phase == .idle })
        coordinator.handle(.released)
        #expect(engine.finishCount == 1)
        #expect(inserter.inserted.count == 1)
    }

    @Test func escapeDuringRecordingDiscardsEverything() async {
        await record()
        coordinator.handle(.escape)
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(engine.cancelCount == 1)
        #expect(engine.finishCount == 0)
        #expect(inserter.inserted.isEmpty)
        #expect(drafts.value.isEmpty)
        #expect(coordinator.latestTranscript == nil)
    }

    @Test func escapeDuringStartupCancelsCapture() async {
        engine.holdStart = true
        coordinator.handle(.pressed)
        #expect(await waitUntil { engine.isWaitingInStart })
        coordinator.handle(.escape)
        engine.releaseStart()
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(engine.cancelCount == 1)
        #expect(engine.finishCount == 0)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func resultOfCancelledSessionIsNeverPasted() async {
        engine.holdFinish = true
        await record()
        coordinator.handle(.released)
        #expect(await waitUntil { engine.isWaitingInFinish })
        coordinator.abort(reason: "The audio device changed during recording.")
        engine.releaseFinish()
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted.isEmpty)
        #expect(drafts.value.isEmpty)
    }

    @Test func escapeOnlyCountsWhileRecording() async {
        engine.holdFinish = true
        await record()
        #expect(coordinator.isRecording)
        coordinator.handle(.released)
        #expect(await waitUntil { engine.isWaitingInFinish })
        // Processing: Escape belongs to the focused app again.
        #expect(!coordinator.isRecording)
        coordinator.handle(.escape)
        engine.releaseFinish()
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted == ["hello world "])
        #expect(!coordinator.isRecording)
    }

    @Test func pressWhileFinalizingIsIgnored() async {
        engine.holdFinish = true
        await record()
        coordinator.handle(.released)
        #expect(await waitUntil { engine.isWaitingInFinish })
        coordinator.handle(.pressed)
        coordinator.handle(.released)
        #expect(engine.startCount == 1)
        engine.releaseFinish()
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted.count == 1)
        #expect(engine.finishCount == 1)
    }

    @Test func otherKeyWhileHoldingCancels() async {
        await record()
        coordinator.handle(.otherKeyWhileHeld)
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted.isEmpty)
    }

    @Test func watchdogStopsWithoutPasting() async {
        coordinator.watchdogDuration = .milliseconds(50)
        await record()
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted.isEmpty)
        #expect(drafts.value.first?.outcome == .copyOnly)
        #expect(coordinator.latestTranscript == "hello world ")
    }

    @Test func missedReleaseIsRecoveredFromHardwareState() async {
        let missed = LockedBox(false)
        coordinator.releasePollInterval = .milliseconds(10)
        coordinator.isShortcutPhysicallyHeld = { false }
        coordinator.onMissedRelease = { missed.value = true }
        coordinator.handle(.pressed)
        #expect(await waitUntil { coordinator.phase == .idle && engine.finishCount == 1 })
        #expect(missed.value)
        #expect(inserter.inserted == ["hello world "])
    }

    @Test func emptyRecognitionLeavesClipboardAndHistoryAlone() async {
        engine.transcript = "  \n "
        await record()
        coordinator.handle(.released)
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted.isEmpty)
        #expect(drafts.value.isEmpty)
    }

    @Test func multilineRecognitionIsPastedAsOneLine() async {
        engine.transcript = "git status\nthen commit"
        await record()
        coordinator.handle(.released)
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(inserter.inserted == ["git status then commit "])
        #expect(drafts.value.first?.text == "git status\nthen commit")
        #expect(drafts.value.first?.insertionText == "git status then commit ")
    }

    @Test func copyOnlyOutcomeIsRecorded() async {
        inserter.result = .copyOnly(.destinationChanged)
        await record()
        coordinator.handle(.released)
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(drafts.value.first?.outcome == .copyOnly)
        #expect(coordinator.notice == PasteSkipReason.destinationChanged.message)
    }

    @Test func notReadyNeverStartsCapture() async {
        coordinator.isReady = { false }
        coordinator.setupProblem = { "Microphone access denied" }
        coordinator.handle(.pressed)
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.handle(.released)
        #expect(engine.startCount == 0)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.notice == "Microphone access denied")
    }

    @Test func secureInputBlocksDictation() async {
        inserter.isSecureInputActive = true
        coordinator.handle(.pressed)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(engine.startCount == 0)
    }

    @Test func startFailureReturnsToIdle() async {
        engine.startError = CaptureError.noInputDevice
        coordinator.handle(.pressed)
        #expect(await waitUntil { coordinator.phase == .idle && coordinator.notice != nil })
        #expect(inserter.inserted.isEmpty)
    }

    @Test func interruptionAbortsRecording() async {
        await record()
        engine.onInterruption?("The audio device changed during recording.")
        #expect(await waitUntil { coordinator.phase == .idle })
        #expect(engine.cancelCount == 1)
        #expect(inserter.inserted.isEmpty)
    }
}

@MainActor
@Suite("Setup and permissions")
struct SetupControllerTests {
    let permissions = FakePermissions()
    let speech = FakeSpeechAssets()
    let tapInstalls = LockedBox(0)
    let tapWorks = LockedBox(true)
    let prepares = LockedBox(0)

    func makeSetup() -> SetupController {
        let tapInstalls = tapInstalls
        let tapWorks = tapWorks
        let prepares = prepares
        return SetupController(
            permissions: permissions,
            speechAssets: speech,
            installEventTap: {
                tapInstalls.mutate { $0 += 1 }
                return tapWorks.value
            },
            prepareRecognizer: { prepares.mutate { $0 += 1 } }
        )
    }

    @Test func notDeterminedIsReportedButNeverRequestedAutomatically() async {
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.snapshot.problem == "Microphone access not set up")
        #expect(permissions.microphoneRequests == 0)
        #expect(!setup.isReady)
    }

    @Test func explicitRequestAsksOnceThenGrantDoesNotStartRecording() async {
        let setup = makeSetup()
        let engine = FakeEngine()
        let coordinator = DictationCoordinator(engine: engine, inserter: FakeInserter())
        coordinator.isReady = { setup.isReadyForRecording() }

        await setup.refresh()
        await setup.grantMicrophone()
        #expect(permissions.microphoneRequests == 1)
        #expect(setup.snapshot.microphone == .authorized)
        #expect(setup.isReady)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(engine.startCount == 0)

        // A fresh press is what starts the recording.
        coordinator.handle(.pressed)
        #expect(await waitUntil { engine.startCount == 1 })
    }

    @Test func deniedNeverPromptsAgainAndBlocksCapture() async {
        permissions.microphone = .denied
        let setup = makeSetup()
        let engine = FakeEngine()
        let coordinator = DictationCoordinator(engine: engine, inserter: FakeInserter())
        coordinator.isReady = { setup.isReadyForRecording() }

        await setup.refresh()
        await setup.grantMicrophone()
        #expect(permissions.microphoneRequests == 0)
        #expect(permissions.openedPanes == [.microphone])
        #expect(setup.snapshot.problem == "Microphone access denied")
        coordinator.handle(.pressed)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(engine.startCount == 0)
    }

    @Test func restrictedExplainsPolicy() async {
        permissions.microphone = .restricted
        let setup = makeSetup()
        await setup.refresh()
        await setup.grantMicrophone()
        #expect(permissions.microphoneRequests == 0)
        #expect(setup.snapshot.problem == "Microphone blocked by system policy")
    }

    @Test func authorizedWithEverythingIsReady() async {
        permissions.microphone = .authorized
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.isReady)
        #expect(tapInstalls.value >= 1)
        #expect(prepares.value == 1)
    }

    @Test func revokedMicrophoneIsCaughtBeforeRecording() async {
        permissions.microphone = .authorized
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.isReady)
        permissions.microphone = .denied
        #expect(!setup.isReadyForRecording())
    }

    @Test func keyboardPermissionsAreCheckedSeparately() async {
        permissions.microphone = .authorized
        permissions.listen = false
        permissions.trusted = false
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.snapshot.problem == "Input Monitoring not allowed")
        #expect(tapInstalls.value == 0)

        permissions.listen = true
        tapWorks.value = false
        await setup.refresh()
        #expect(setup.snapshot.problem == "Accessibility not allowed")
    }

    @Test func runningTapCountsAsKeyboardAccess() async {
        permissions.microphone = .authorized
        permissions.listen = false
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.snapshot.eventTapInstalled)
        #expect(setup.isReady)
    }

    @Test func grantedButTapMissingSuggestsRelaunch() async {
        permissions.microphone = .authorized
        tapWorks.value = false
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.snapshot.mayNeedRelaunch)
        #expect(setup.snapshot.problem?.contains("Quit and reopen") == true)
    }

    @Test func grantInputMonitoringRegistersTheAppThenOpensThePane() async {
        permissions.microphone = .authorized
        permissions.listen = false
        let setup = makeSetup()
        await setup.refresh()
        setup.grantInputMonitoring()
        #expect(permissions.listenRequests == 1)
        #expect(permissions.openedPanes == [.inputMonitoring])
    }

    @Test func grantingWhileRunningRecommendsARelaunch() async {
        permissions.microphone = .authorized
        permissions.listen = false
        permissions.trusted = false
        tapWorks.value = false
        let setup = makeSetup()
        await setup.refresh()
        #expect(!setup.snapshot.relaunchRecommended)

        // The user switches it on in System Settings and comes back.
        permissions.listen = true
        setup.refreshPermissions()
        #expect(setup.snapshot.relaunchRecommended)
        #expect(setup.snapshot.mayNeedRelaunch)
    }

    @Test func alreadyGrantedInputMonitoringDoesNotOpenSettings() async {
        permissions.microphone = .authorized
        let setup = makeSetup()
        await setup.refresh()
        setup.grantInputMonitoring()
        #expect(permissions.listenRequests == 0)
        #expect(permissions.openedPanes.isEmpty)
    }

    @Test func speechModelMustBeInstalledBeforeReady() async {
        permissions.microphone = .authorized
        speech.state = .notInstalled
        let setup = makeSetup()
        await setup.refresh()
        #expect(setup.snapshot.problem == "English speech model not downloaded")
        #expect(prepares.value == 0)

        await setup.installSpeechModel()
        #expect(speech.installs == 1)
        #expect(setup.isReady)
        #expect(prepares.value == 1)
    }
}
