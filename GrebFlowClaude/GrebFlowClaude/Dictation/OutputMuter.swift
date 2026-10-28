import CoreAudio
import Foundation
import Observation
import os

/// The few Core Audio calls the muter needs, behind a protocol so tests can
/// fake an output device.
@MainActor
protocol OutputMuteControl: AnyObject {
    func defaultOutputDevice() -> AudioDeviceID?
    func device(forUID uid: String) -> AudioDeviceID?
    func uid(of device: AudioDeviceID) -> String?
    func name(of device: AudioDeviceID) -> String?
    /// True only if the device has a main-element output mute that can be set.
    func canMute(_ device: AudioDeviceID) -> Bool
    func isMuted(_ device: AudioDeviceID) -> Bool?
    @discardableResult func setMuted(_ muted: Bool, _ device: AudioDeviceID) -> Bool
}

/// Mutes the current output device while the dictation key is held, so music
/// doesn't compete with your voice. Music keeps playing; you just don't hear
/// it. Only the device's mute switch is touched, never its volume.
///
/// It only unmutes a device it muted itself. A device that was already muted
/// stays muted, and if you unmute during a recording, that sticks.
@MainActor
@Observable
final class OutputMuter {
    /// Set when the last recording couldn't mute the output, for Settings.
    private(set) var limitation: String?

    @ObservationIgnored var isEnabled: () -> Bool = { false }
    @ObservationIgnored private let control: OutputMuteControl
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "mute")
    @ObservationIgnored private var mutedDevice: AudioDeviceID?

    /// The UID of a device we muted, kept until it's restored. If the app
    /// dies mid-recording, the next launch unmutes it.
    private static let pendingKey = "muteOutput.pendingDeviceUID"

    init(control: OutputMuteControl, defaults: UserDefaults = .standard) {
        self.control = control
        self.defaults = defaults
    }

    func recordingStarted() {
        guard isEnabled(), mutedDevice == nil, let device = control.defaultOutputDevice() else { return }
        guard control.canMute(device) else {
            let name = control.name(of: device) ?? "The current output"
            limitation = "\(name) can't be muted, so it kept playing during dictation."
            logger.notice("Output device has no settable mute")
            return
        }
        limitation = nil
        guard control.isMuted(device) == false else { return }
        guard control.setMuted(true, device) else {
            logger.error("Muting the output device failed")
            return
        }
        mutedDevice = device
        defaults.set(control.uid(of: device), forKey: Self.pendingKey)
    }

    /// Called on release, cancel, failure, sleep, quit, and when the setting
    /// is turned off. Safe to call when nothing is muted.
    func restore() {
        guard let device = mutedDevice else { return }
        mutedDevice = nil
        defaults.removeObject(forKey: Self.pendingKey)
        // If you unmuted it yourself while talking, leave it.
        if control.isMuted(device) == true, !control.setMuted(false, device) {
            logger.error("Unmuting the output device failed")
        }
    }

    /// Best effort after a crash or force quit during a recording.
    func recoverInterruptedSession() {
        guard let uid = defaults.string(forKey: Self.pendingKey) else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        guard let device = control.device(forUID: uid), control.isMuted(device) == true else { return }
        control.setMuted(false, device)
        logger.notice("Unmuted output left muted by an interrupted session")
    }
}

@MainActor
final class CoreAudioMuteControl: OutputMuteControl {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    func defaultOutputDevice() -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func device(forUID uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func uid(of device: AudioDeviceID) -> String? {
        string(kAudioDevicePropertyDeviceUID, of: device)
    }

    func name(of device: AudioDeviceID) -> String? {
        string(kAudioObjectPropertyName, of: device)
    }

    func canMute(_ device: AudioDeviceID) -> Bool {
        var address = Self.muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = Self.muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func setMuted(_ muted: Bool, _ device: AudioDeviceID) -> Bool {
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
