import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid

enum MicrophoneAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum ListenAccess: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

/// The capability checks dictation depends on. Each request is only ever
/// called from an explicit setup action, never from the shortcut path.
@MainActor
protocol PermissionProviding: AnyObject {
    func microphoneStatus() -> MicrophoneAuthorization
    func requestMicrophone() async -> Bool
    func listenAccess() -> ListenAccess
    /// Registers the app under Input Monitoring and shows the system prompt
    /// the first time. Returns true if access is already granted.
    func requestListenAccess() -> Bool
    func canPostEvents() -> Bool
    func requestPostAccess()
    func isAccessibilityTrusted() -> Bool
    func promptAccessibility()
    func openPrivacyPane(_ pane: PrivacyPane)
}

@MainActor
final class SystemPermissions: PermissionProviding {
    func microphoneStatus() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func listenAccess() -> ListenAccess {
        if CGPreflightListenEventAccess() { return .granted }
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    /// IOHIDRequestAccess is the call that adds the app to the Input
    /// Monitoring list. Without it the pane has nothing to switch on.
    func requestListenAccess() -> Bool {
        let hid = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let cg = CGRequestListenEventAccess()
        return hid || cg
    }

    func canPostEvents() -> Bool { CGPreflightPostEventAccess() }

    func requestPostAccess() { _ = CGRequestPostEventAccess() }

    func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacyPane(_ pane: PrivacyPane) {
        pane.open()
    }
}

enum PrivacyPane: String {
    case microphone = "Privacy_Microphone"
    case inputMonitoring = "Privacy_ListenEvent"
    case accessibility = "Privacy_Accessibility"

    /// Written path, shown next to the button in case the deep link stops
    /// working on a future macOS version.
    var navigationPath: String {
        switch self {
        case .microphone: "System Settings > Privacy & Security > Microphone"
        case .inputMonitoring: "System Settings > Privacy & Security > Input Monitoring"
        case .accessibility: "System Settings > Privacy & Security > Accessibility"
        }
    }

    @MainActor
    func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
