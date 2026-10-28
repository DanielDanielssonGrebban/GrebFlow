import Foundation
import Observation
import ServiceManagement

/// Launch at login through SMAppService.mainApp. Shows the real registration
/// state, including when macOS wants the user to approve it.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    var statusDescription: String {
        switch status {
        case .enabled: "Enabled"
        case .notRegistered: "Off"
        case .requiresApproval: "Waiting for approval in System Settings > General > Login Items"
        case .notFound: "Not found. Run GrebFlowClaude from a stable app location and try again."
        @unknown default: "Unknown"
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
