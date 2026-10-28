import CoreAudio
import Foundation
import Testing
@testable import GrebFlowClaude

@MainActor
final class FakeMuteControl: OutputMuteControl {
    var defaultDevice: AudioDeviceID? = 1
    var mutable: Set<AudioDeviceID> = [1, 2]
    var muted: Set<AudioDeviceID> = []
    private(set) var setCalls = 0

    func defaultOutputDevice() -> AudioDeviceID? { defaultDevice }
    func device(forUID uid: String) -> AudioDeviceID? { AudioDeviceID(uid.dropFirst(4)) }
    func uid(of device: AudioDeviceID) -> String? { "uid-\(device)" }
    func name(of device: AudioDeviceID) -> String? { "Device \(device)" }
    func canMute(_ device: AudioDeviceID) -> Bool { mutable.contains(device) }
    func isMuted(_ device: AudioDeviceID) -> Bool? { muted.contains(device) }
    func setMuted(_ value: Bool, _ device: AudioDeviceID) -> Bool {
        setCalls += 1
        if value { muted.insert(device) } else { muted.remove(device) }
        return true
    }
}

@MainActor
@Suite("Muting output while recording")
struct OutputMuterTests {
    let control = FakeMuteControl()
    let defaults = UserDefaults(suiteName: "OutputMuterTests.\(UUID())")!
    let muter: OutputMuter

    init() {
        muter = OutputMuter(control: control, defaults: defaults)
        muter.isEnabled = { true }
    }

    @Test func mutesOnStartAndRestoresOnEnd() {
        muter.recordingStarted()
        #expect(control.muted == [1])
        muter.restore()
        #expect(control.muted.isEmpty)
        muter.restore()
        #expect(control.setCalls == 2)
    }

    @Test func doesNothingWhenTurnedOff() {
        muter.isEnabled = { false }
        muter.recordingStarted()
        muter.restore()
        #expect(control.setCalls == 0)
    }

    @Test func leavesAnAlreadyMutedDeviceMuted() {
        control.muted = [1]
        muter.recordingStarted()
        muter.restore()
        #expect(control.muted == [1])
        #expect(control.setCalls == 0)
    }

    @Test func keepsAnUnmuteMadeDuringRecording() {
        muter.recordingStarted()
        control.muted = []
        muter.restore()
        #expect(control.muted.isEmpty)
        #expect(control.setCalls == 1)
    }

    @Test func restoresTheDeviceItMutedAfterTheOutputChanges() {
        muter.recordingStarted()
        control.defaultDevice = 2
        muter.restore()
        #expect(control.muted.isEmpty)
    }

    @Test func reportsOutputsThatCantBeMuted() {
        control.mutable = []
        muter.recordingStarted()
        #expect(control.setCalls == 0)
        #expect(muter.limitation == "Device 1 can't be muted, so it kept playing during dictation.")
        control.mutable = [1]
        muter.recordingStarted()
        #expect(muter.limitation == nil)
    }

    @Test func nextLaunchUnmutesAfterAnInterruptedSession() {
        muter.recordingStarted()
        // The app dies here. A new instance finds the leftover marker.
        let relaunched = OutputMuter(control: control, defaults: defaults)
        relaunched.recoverInterruptedSession()
        #expect(control.muted.isEmpty)
        relaunched.recoverInterruptedSession()
        #expect(control.setCalls == 2)
    }

    @Test func noRecoveryAfterANormalRestore() {
        muter.recordingStarted()
        muter.restore()
        control.muted = [1]
        OutputMuter(control: control, defaults: defaults).recoverInterruptedSession()
        #expect(control.muted == [1])
    }
}
