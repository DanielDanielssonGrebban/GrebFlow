import AppKit
import Foundation
import Observation
import os

/// Composition root. Owns the long-lived services and the small amount of
/// glue between them. Views read from here and call its actions; none of the
/// services depend on views.
@MainActor
@Observable
final class AppModel {
    static let bundleID = "com.grebban.GrebFlowClaude"

    let preferences: Preferences
    let realStore: HistoryStore
    let sampleStore: HistoryStore
    let setup: SetupController
    let coordinator: DictationCoordinator
    let analysis: AnalysisCoordinator
    let insights: InsightsModel
    let apiKey: APIKeyController
    let loginItem: LoginItemController

    private(set) var storageError: String?

    @ObservationIgnored let shortcutMonitor: ShortcutMonitor
    @ObservationIgnored private let engine: LiveDictationEngine
    @ObservationIgnored private let clipboard: ClipboardOwnership
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let logger = Logger(subsystem: bundleID, category: "app")

    init(
        preferences: Preferences,
        realStore: HistoryStore,
        sampleStore: HistoryStore,
        secrets: SecretStore,
        client: AnthropicClient
    ) {
        self.preferences = preferences
        self.realStore = realStore
        self.sampleStore = sampleStore

        let clipboard = ClipboardOwnership()
        let engine = LiveDictationEngine()
        let monitor = ShortcutMonitor(shortcut: preferences.shortcut)
        self.clipboard = clipboard
        self.engine = engine
        shortcutMonitor = monitor

        setup = SetupController(
            permissions: SystemPermissions(),
            speechAssets: SpeechAssets(),
            installEventTap: { monitor.install() },
            prepareRecognizer: { try await engine.prepare() }
        )
        let coordinator = DictationCoordinator(
            engine: engine,
            inserter: PasteInserter(environment: SystemPasteEnvironment(clipboard: clipboard))
        )
        self.coordinator = coordinator
        analysis = AnalysisCoordinator(
            client: client,
            secrets: secrets,
            preferences: preferences,
            stores: { $0 == .real ? realStore : sampleStore },
            isDictationIdle: { coordinator.phase == .idle }
        )
        insights = InsightsModel()
        apiKey = APIKeyController(secrets: secrets, client: client)
        loginItem = LoginItemController()

        wireUp()
    }

    /// Stores live in their own folder under Application Support, so they
    /// never collide with GrebFlowSol or GrebFlowArgon.
    static func live() throws -> AppModel {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appending(path: bundleID, directoryHint: .isDirectory)
        return AppModel(
            preferences: Preferences(),
            realStore: HistoryStore(dataset: .real, container: try HistoryStore.makeContainer(for: .real, directory: directory)),
            sampleStore: HistoryStore(dataset: .sample, container: try HistoryStore.makeContainer(for: .sample, directory: directory)),
            secrets: KeychainStore(service: bundleID, account: "anthropic-api-key"),
            client: AnthropicClient()
        )
    }

    private func wireUp() {
        let setup = setup
        let coordinator = coordinator
        let monitor = shortcutMonitor
        let preferences = preferences

        coordinator.isReady = { setup.isReadyForRecording() }
        coordinator.setupProblem = { setup.snapshot.problem }
        coordinator.shortcut = { preferences.shortcut }
        coordinator.isShortcutPhysicallyHeld = {
            ShortcutInterpreter.isRightKeyDown(
                shortcut: preferences.shortcut,
                flags: CGEventSource.flagsState(.hidSystemState).rawValue
            )
        }
        coordinator.onMissedRelease = { monitor.resetHeldState() }
        coordinator.onTranscript = { [weak self] draft in
            self?.record(draft)
        }

        monitor.onAction = { action in coordinator.handle(action) }
        monitor.shouldConsumeEscape = { coordinator.isRecording }

        analysis.onBatchSaved = { [weak self] dataset in
            guard let self, dataset == self.selectedDataset else { return }
            self.refreshInsights()
        }
        apiKey.onChange = { [weak self] in self?.analysis.credentialsChanged() }
    }

    // MARK: Lifecycle

    func start() {
        do {
            try DemoSeeder.seedIfEmpty(sampleStore, now: Date())
        } catch {
            storageError = "Couldn't create sample data: \(error.localizedDescription)"
        }
        refreshInsights()
        Task { await setup.refresh() }
        analysis.schedule()

        // Permission checks are cheap; poll so the menu reflects changes made
        // in System Settings, including revoked access.
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.periodicSetupCheck() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { @Sendable _ in
            Task { @MainActor [weak self] in
                self?.coordinator.abort(reason: "Recording stopped because the Mac went to sleep.")
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { @Sendable _ in
            Task { @MainActor [weak self] in
                await self?.setup.refresh()
            }
        })
    }

    func shutdown() {
        coordinator.abort(reason: "GrebFlowClaude is quitting.")
        analysis.cancelAll()
        shortcutMonitor.uninstall()
        timers.forEach { $0.invalidate() }
    }

    private func periodicSetupCheck() {
        let wasReady = setup.isReady
        setup.refreshPermissions()
        if !setup.isReady || !wasReady {
            Task { await setup.refresh() }
        }
        if setup.snapshot.microphone != .authorized, coordinator.isActive {
            coordinator.abort(reason: "Microphone access was turned off.")
        }
    }

    // MARK: History

    var selectedDataset: Dataset {
        get { preferences.dataset }
        set {
            guard newValue != preferences.dataset else { return }
            // Switching only changes what's shown. It never grants consent.
            preferences.dataset = newValue
            refreshInsights()
        }
    }

    func store(for dataset: Dataset) -> HistoryStore {
        dataset == .real ? realStore : sampleStore
    }

    func refreshInsights() {
        insights.refresh(from: store(for: selectedDataset))
    }

    private func record(_ draft: TranscriptDraft) {
        // Live dictation always goes to real history, whatever the dashboard
        // is showing. Saving happens after the paste attempt.
        do {
            try realStore.add(draft)
            storageError = nil
        } catch {
            storageError = "Couldn't save the last transcript: \(error.localizedDescription)"
            logger.error("Transcript save failed")
        }
        if selectedDataset == .real { refreshInsights() }
        analysis.transcriptAdded()
    }

    func setShortcut(_ shortcut: DictationShortcut) {
        coordinator.cancel(notice: nil)
        preferences.shortcut = shortcut
        shortcutMonitor.shortcut = shortcut
    }

    func setAnalysisEnabled(_ enabled: Bool, for dataset: Dataset) {
        analysis.setEnabled(enabled, for: dataset)
    }

    /// Clears real and sample transcripts with their groups, memberships,
    /// and analysis progress. Cancels analysis, and clears the clipboard only
    /// if it still holds text this app put there. Keeps the API key and
    /// preferences.
    func deleteAllHistory() {
        analysis.cancelAll()
        do {
            try realStore.deleteAll()
            try sampleStore.deleteAll()
            storageError = nil
        } catch {
            storageError = "Delete failed: \(error.localizedDescription)"
        }
        coordinator.clearLatestTranscript()
        clipboard.clearIfOwned()
        refreshInsights()
        analysis.historyReset(.real)
        analysis.historyReset(.sample)
    }

    /// Recreates the sample history and drops its groups and pending analysis.
    func resetSampleData() {
        do {
            try DemoSeeder.reset(sampleStore, now: Date())
        } catch {
            storageError = "Couldn't reset sample data: \(error.localizedDescription)"
        }
        analysis.historyReset(.sample)
        refreshInsights()
    }

    func copy(_ text: String) {
        clipboard.write(text)
    }

    func copyLatestTranscript() {
        guard let text = coordinator.latestTranscript else { return }
        clipboard.write(text)
    }

    /// Permission changes made in System Settings may not reach a running
    /// process. Reopen the same bundle from the same path.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
