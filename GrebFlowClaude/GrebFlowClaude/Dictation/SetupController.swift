import Foundation
import Observation

struct SetupSnapshot: Equatable, Sendable {
    var microphone: MicrophoneAuthorization = .notDetermined
    var canListen = false
    var canPost = false
    var accessibilityTrusted = false
    var eventTapInstalled = false
    var speech: SpeechAssetState = .unknown
    var recognizerPrepared = false
    var recognizerError: String?
    var modelName = "English speech model"
    var preparingMessage = "Preparing recognizer"
    /// A keyboard permission was granted while the app was running. macOS
    /// usually only applies it after a restart.
    var relaunchRecommended = false

    var isReady: Bool { problem == nil }

    /// The first thing standing between the user and dictation, worded for
    /// the menu and Settings.
    var problem: String? {
        switch microphone {
        case .notDetermined: return "Microphone access not set up"
        case .denied: return "Microphone access denied"
        case .restricted: return "Microphone blocked by system policy"
        case .authorized: break
        }
        // A running active tap proves keyboard access even if the Input
        // Monitoring preflight says no.
        if !canListen && !eventTapInstalled { return "Input Monitoring not allowed" }
        if !accessibilityTrusted || !canPost { return "Accessibility not allowed" }
        if !eventTapInstalled { return "Shortcut listener not running. Quit and reopen GrebFlowClaude." }
        switch speech {
        case .installed: break
        case .unsupported: return "\(modelName) unsupported"
        case .downloading: return "Downloading \(modelName)"
        case .failed: return "\(modelName) download failed"
        case .unknown: return "Checking \(modelName)"
        case .notInstalled: return "\(modelName) not downloaded"
        }
        if let recognizerError { return "Recognizer failed to prepare: \(recognizerError)" }
        if !recognizerPrepared { return preparingMessage }
        return nil
    }

    /// Accessibility or Input Monitoring granted in System Settings often
    /// doesn't reach a process that is already running.
    var mayNeedRelaunch: Bool {
        relaunchRecommended || (canListen && accessibilityTrusted && canPost && !eventTapInstalled)
    }
}

/// Checks every dictation prerequisite and runs the explicit setup actions.
/// Requests only happen from a user action. Granting something never starts
/// a recording; the user has to press the shortcut again.
@MainActor
@Observable
final class SetupController {
    private(set) var snapshot = SetupSnapshot()

    @ObservationIgnored private let permissions: PermissionProviding
    @ObservationIgnored private let speechAssets: SpeechAssetProviding
    @ObservationIgnored private let installEventTap: () -> Bool
    @ObservationIgnored private let prepareRecognizer: () async throws -> Void
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var isInstallingSpeech = false
    /// Bumped when the user picks another recognizer, so results from work
    /// started for the old one are ignored.
    @ObservationIgnored private var recognizerGeneration = 0
    /// Keyboard permissions as they were at launch.
    @ObservationIgnored private var launchGrants: (listen: Bool, accessibility: Bool)?

    init(
        permissions: PermissionProviding,
        speechAssets: SpeechAssetProviding,
        installEventTap: @escaping () -> Bool,
        prepareRecognizer: @escaping () async throws -> Void
    ) {
        self.permissions = permissions
        self.speechAssets = speechAssets
        self.installEventTap = installEventTap
        self.prepareRecognizer = prepareRecognizer
    }

    var isReady: Bool { snapshot.isReady }

    /// Re-reads microphone authorization right before a recording. The
    /// other checks are refreshed on activation, menu open, and a timer.
    func isReadyForRecording() -> Bool {
        snapshot.microphone = permissions.microphoneStatus()
        return snapshot.isReady
    }

    func refreshPermissions() {
        snapshot.microphone = permissions.microphoneStatus()
        snapshot.canListen = permissions.listenAccess() == .granted
        snapshot.canPost = permissions.canPostEvents()
        snapshot.accessibilityTrusted = permissions.isAccessibilityTrusted()
        if let launchGrants {
            if (snapshot.canListen && !launchGrants.listen) || (snapshot.accessibilityTrusted && !launchGrants.accessibility) {
                snapshot.relaunchRecommended = true
            }
        } else {
            launchGrants = (snapshot.canListen, snapshot.accessibilityTrusted)
        }
        if snapshot.canListen || snapshot.accessibilityTrusted {
            snapshot.eventTapInstalled = installEventTap()
        } else {
            snapshot.eventTapInstalled = false
        }
    }

    func refresh() async {
        refreshPermissions()
        snapshot.modelName = speechAssets.modelName
        snapshot.preparingMessage = speechAssets.preparingMessage
        if !isInstallingSpeech {
            snapshot.speech = await speechAssets.status()
        }
        await prepareIfPossible()
    }

    /// The selected recognizer changed. Its model may not be downloaded or
    /// loaded yet, so start over from the status check.
    func recognizerChanged() async {
        recognizerGeneration += 1
        isInstallingSpeech = false
        snapshot.speech = .unknown
        snapshot.recognizerPrepared = false
        snapshot.recognizerError = nil
        await refresh()
    }

    /// One button per permission. macOS only shows its own dialog once, so
    /// after that the button opens the right System Settings pane instead.
    func grantMicrophone() async {
        switch permissions.microphoneStatus() {
        case .notDetermined:
            _ = await permissions.requestMicrophone()
        case .denied:
            permissions.openPrivacyPane(.microphone)
        case .authorized, .restricted:
            break
        }
        refreshPermissions()
    }

    /// Registers GrebFlowClaude under Input Monitoring, then opens that pane
    /// so the app is already listed and only needs switching on.
    func grantInputMonitoring() {
        if permissions.listenAccess() != .granted {
            _ = permissions.requestListenAccess()
        }
        refreshPermissions()
        if !snapshot.canListen {
            permissions.openPrivacyPane(.inputMonitoring)
        }
    }

    /// Adds GrebFlowClaude to the Accessibility list and opens that pane.
    func grantAccessibility() {
        permissions.promptAccessibility()
        permissions.requestPostAccess()
        refreshPermissions()
        if !(snapshot.accessibilityTrusted && snapshot.canPost) {
            permissions.openPrivacyPane(.accessibility)
        }
    }

    func installSpeechModel() async {
        guard !isInstallingSpeech else { return }
        let generation = recognizerGeneration
        isInstallingSpeech = true
        snapshot.speech = .downloading(0)
        do {
            try await speechAssets.install { [weak self] fraction in
                guard let self, self.recognizerGeneration == generation else { return }
                self.snapshot.speech = .downloading(fraction)
            }
            guard recognizerGeneration == generation else { return }
            snapshot.speech = await speechAssets.status()
        } catch {
            guard recognizerGeneration == generation else { return }
            snapshot.speech = .failed(error.localizedDescription)
        }
        isInstallingSpeech = false
        await prepareIfPossible()
    }

    private func prepareIfPossible() async {
        guard snapshot.speech == .installed, !snapshot.recognizerPrepared, !isPreparing else { return }
        let generation = recognizerGeneration
        isPreparing = true
        do {
            try await prepareRecognizer()
            isPreparing = false
            guard recognizerGeneration == generation else { return await prepareIfPossible() }
            snapshot.recognizerPrepared = true
            snapshot.recognizerError = nil
        } catch {
            isPreparing = false
            guard recognizerGeneration == generation else { return await prepareIfPossible() }
            snapshot.recognizerError = error.localizedDescription
        }
    }
}
