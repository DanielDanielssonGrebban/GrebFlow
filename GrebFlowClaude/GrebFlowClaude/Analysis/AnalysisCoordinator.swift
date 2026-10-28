import Foundation
import Observation
import os

enum AnalysisState: Equatable, Sendable {
    case off
    case needsKey
    case idle
    case waiting
    case running
    case paused(String)
    case budgetReached(resetsAt: Date)

    var label: String {
        switch self {
        case .off: "Off"
        case .needsKey: "Needs an API key"
        case .idle: "Up to date"
        case .waiting: "Waiting for dictation to go idle"
        case .running: "Analyzing a batch…"
        case let .paused(reason): "Paused: \(reason)"
        case let .budgetReached(resetsAt): "Daily budget reached. Resumes \(resetsAt.formatted(date: .omitted, time: .shortened))."
        }
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

/// Initial batching and cost limits. Short dictations are a few dozen tokens
/// each, so a full batch is roughly 2–3k input tokens.
struct AnalysisLimits: Sendable {
    /// Transcripts per request.
    var batchSize = 20
    /// Quiet time after the last dictation before a batch starts.
    var idleDelay: Duration = .seconds(10)
    /// Gap between back-to-back batches while working through a backlog.
    var continueDelay: Duration = .seconds(2)
    /// Output allowance per request.
    var maxOutputTokens = 4_096
    /// Per local calendar day, per app.
    var dailyRequestLimit = 100
    var dailyTokenLimit = 500_000
    /// Used if the Models API doesn't report a context window.
    var fallbackContextTokens = 200_000
    /// Messages API request size limit.
    var maxRequestBytes = 32 * 1024 * 1024
}

/// Runs AI grouping in the background, one request at a time for the whole
/// app, only for datasets the user has opted in. Never retries a failed
/// request by itself; it pauses and waits for Retry.
@MainActor
@Observable
final class AnalysisCoordinator {
    private var states: [Dataset: AnalysisState] = [:]
    private(set) var requestsToday = 0
    private(set) var tokensToday = 0

    @ObservationIgnored var onBatchSaved: (Dataset) -> Void = { _ in }
    @ObservationIgnored let limits: AnalysisLimits
    @ObservationIgnored private let client: AnthropicClient
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let stores: (Dataset) -> HistoryStore
    @ObservationIgnored private let isDictationIdle: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "analysis")

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var budgetWake: Task<Void, Never>?
    @ObservationIgnored private var inFlight: (dataset: Dataset, token: UUID, task: Task<Void, Never>)?
    /// Bumped whenever consent or the key is withdrawn for a dataset. A
    /// response from an older authorization is discarded.
    @ObservationIgnored private var authorization: [Dataset: Int] = [:]
    /// Smaller batch size after a truncated response, until a batch succeeds.
    @ObservationIgnored private var batchLimits: [Dataset: Int] = [:]
    @ObservationIgnored private var modelInfo: [String: ModelInfo] = [:]

    init(
        client: AnthropicClient,
        secrets: SecretStore,
        preferences: Preferences,
        stores: @escaping (Dataset) -> HistoryStore,
        limits: AnalysisLimits = AnalysisLimits(),
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        isDictationIdle: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.secrets = secrets
        self.preferences = preferences
        self.stores = stores
        self.limits = limits
        self.defaults = defaults
        self.calendar = calendar
        self.isDictationIdle = isDictationIdle
        self.now = now
        loadBudget()
    }

    // MARK: State

    func state(for dataset: Dataset) -> AnalysisState {
        guard preferences.isAnalysisEnabled(for: dataset) else { return .off }
        guard hasKey else { return .needsKey }
        return states[dataset] ?? .idle
    }

    var isRequestInFlight: Bool { inFlight != nil }

    private var hasKey: Bool {
        ((try? secrets.read()) ?? nil)?.isEmpty == false
    }

    // MARK: Actions

    /// Consent is per dataset. Turning it off cancels work and rejects any
    /// late response from the request in flight.
    func setEnabled(_ enabled: Bool, for dataset: Dataset) {
        preferences.setAnalysisEnabled(enabled, for: dataset)
        if enabled {
            states[dataset] = .idle
            schedule(after: .zero)
        } else {
            revoke(dataset)
        }
    }

    /// Call after the API key is saved, replaced, or removed.
    func credentialsChanged() {
        for dataset in Dataset.allCases { revoke(dataset) }
        if hasKey { schedule(after: .zero) }
    }

    /// Call after Delete all history or Reset sample data. The store's
    /// deletion generation already blocks late saves; this also stops the
    /// request and clears any pause.
    func historyReset(_ dataset: Dataset) {
        revoke(dataset)
        batchLimits[dataset] = nil
        schedule()
    }

    /// Call when a new transcript was saved. Waits for dictation to stay idle.
    func transcriptAdded() {
        schedule()
    }

    func retry(_ dataset: Dataset) {
        states[dataset] = .idle
        schedule(after: .zero)
    }

    func cancelAll() {
        debounce?.cancel()
        for dataset in Dataset.allCases { revoke(dataset) }
    }

    private func revoke(_ dataset: Dataset) {
        authorization[dataset, default: 0] += 1
        if let inFlight, inFlight.dataset == dataset {
            inFlight.task.cancel()
            self.inFlight = nil
        }
        states[dataset] = .idle
    }

    // MARK: Scheduling

    func schedule(after delay: Duration? = nil) {
        let delay = delay ?? limits.idleDelay
        for dataset in Dataset.allCases where canRun(dataset) && (states[dataset] ?? .idle) == .idle {
            if ((try? stores(dataset).pendingCount()) ?? 0) > 0 { states[dataset] = .waiting }
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func canRun(_ dataset: Dataset) -> Bool {
        guard preferences.isAnalysisEnabled(for: dataset), hasKey else { return false }
        switch states[dataset] ?? .idle {
        case .idle, .waiting: return true
        default: return false
        }
    }

    /// Starts the next batch if nothing is in flight and dictation is idle.
    func pump() {
        guard inFlight == nil else { return }
        guard isDictationIdle() else {
            schedule()
            return
        }
        rollBudgetDayIfNeeded()

        for dataset in Dataset.allCases {
            guard canRun(dataset) else { continue }
            let pending = (try? stores(dataset).pendingCount()) ?? 0
            guard pending > 0 else {
                states[dataset] = .idle
                continue
            }
            guard requestsToday < limits.dailyRequestLimit, tokensToday < limits.dailyTokenLimit else {
                pauseForBudget(dataset)
                continue
            }
            start(dataset)
            return
        }
    }

    private func start(_ dataset: Dataset) {
        let token = UUID()
        let epoch = authorization[dataset, default: 0]
        states[dataset] = .running
        let task = Task { [weak self] in
            await self?.runBatch(dataset, epoch: epoch)
            self?.finished(token)
        }
        inFlight = (dataset, token, task)
    }

    private func finished(_ token: UUID) {
        guard inFlight?.token == token else { return }
        inFlight = nil
        schedule(after: limits.continueDelay)
    }

    // MARK: One batch

    private func runBatch(_ dataset: Dataset, epoch: Int) async {
        let store = stores(dataset)
        let modelID = preferences.modelID
        let generation = store.deletionGeneration
        var submitted = 0
        do {
            guard let key = try secrets.read(), !key.isEmpty else {
                states[dataset] = .idle
                return
            }
            let info = try await model(modelID, apiKey: key)
            try Task.checkCancellation()

            let contextLimit = info.maxInputTokens ?? limits.fallbackContextTokens
            let outputTokens = min(limits.maxOutputTokens, info.maxTokens ?? limits.maxOutputTokens)
            let groups = try store.groupDefinitions()
            var pending = try store.pendingTranscripts(limit: batchLimits[dataset] ?? limits.batchSize)
            var request = GroupingPrompt.build(transcripts: pending, groups: groups)

            // Split rather than truncate. A transcript that can't fit even on
            // its own stays visibly unanalyzed.
            while !fits(request, contextLimit: contextLimit, outputTokens: outputTokens) {
                guard pending.count > 1 else {
                    if !fits(GroupingPrompt.build(transcripts: [], groups: groups), contextLimit: contextLimit, outputTokens: outputTokens) {
                        states[dataset] = .paused("The existing group definitions no longer fit in one request.")
                        return
                    }
                    try store.markBlocked(pending.map(\.id), reason: "Too long to analyze in one request.")
                    states[dataset] = .idle
                    onBatchSaved(dataset)
                    return
                }
                pending = Array(pending.prefix(pending.count / 2))
                request = GroupingPrompt.build(transcripts: pending, groups: groups)
            }
            submitted = pending.count

            let estimate = estimatedTokens(request)
            guard requestsToday < limits.dailyRequestLimit, tokensToday + estimate + outputTokens <= limits.dailyTokenLimit else {
                pauseForBudget(dataset)
                return
            }

            recordUsage(requests: 1, tokens: 0)
            let result = try await client.createMessage(
                model: modelID, maxTokens: outputTokens,
                system: request.system, userMessage: request.userMessage, apiKey: key
            )
            recordUsage(requests: 0, tokens: (result.inputTokens ?? estimate) + (result.outputTokens ?? outputTokens))
            try Task.checkCancellation()

            let batch = try GroupingPrompt.validate(
                result.text, for: request,
                modelID: result.model.isEmpty ? modelID : result.model,
                inputTokens: result.inputTokens, outputTokens: result.outputTokens
            )

            // Recheck dataset, consent, key, and deletion before saving.
            guard authorization[dataset, default: 0] == epoch,
                  preferences.isAnalysisEnabled(for: dataset),
                  hasKey,
                  stores(dataset) === store
            else { return }

            switch try store.applyBatch(batch, expectedGeneration: generation, now: now()) {
            case .saved:
                batchLimits[dataset] = nil
                states[dataset] = .idle
                logger.info("Saved a grouping batch of \(batch.sourceIDs.count) transcripts")
                onBatchSaved(dataset)
            case .historyDeleted, .sourcesMissing:
                states[dataset] = .idle
            }
        } catch is CancellationError {
            settleAfterCancel(dataset, epoch: epoch)
        } catch AnthropicError.cancelled {
            settleAfterCancel(dataset, epoch: epoch)
        } catch {
            guard authorization[dataset, default: 0] == epoch else { return }
            if case AnthropicError.truncated = error {
                batchLimits[dataset] = max(1, submitted / 2)
            }
            logger.notice("Grouping batch failed; queue paused")
            states[dataset] = .paused(error.localizedDescription)
        }
    }

    private func settleAfterCancel(_ dataset: Dataset, epoch: Int) {
        if authorization[dataset, default: 0] == epoch { states[dataset] = .idle }
    }

    private func model(_ id: String, apiKey: String) async throws -> ModelInfo {
        if let cached = modelInfo[id] { return cached }
        let info = try await client.model(id: id, apiKey: apiKey)
        modelInfo[id] = info
        return info
    }

    private func fits(_ request: GroupingRequest, contextLimit: Int, outputTokens: Int) -> Bool {
        let bytes = request.system.utf8.count + request.userMessage.utf8.count + 512
        return bytes <= limits.maxRequestBytes && estimatedTokens(request) + outputTokens <= contextLimit
    }

    /// Deliberately high: about three bytes per token, where English text
    /// usually runs closer to four.
    private func estimatedTokens(_ request: GroupingRequest) -> Int {
        (request.system.utf8.count + request.userMessage.utf8.count) / 3 + 64
    }

    // MARK: Budget

    private func pauseForBudget(_ dataset: Dataset) {
        let start = calendar.startOfDay(for: now())
        let reset = calendar.date(byAdding: .day, value: 1, to: start) ?? now().addingTimeInterval(86_400)
        states[dataset] = .budgetReached(resetsAt: reset)
        budgetWake?.cancel()
        let wait = max(1, reset.timeIntervalSince(now()))
        budgetWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.rollBudgetDayIfNeeded()
            self.schedule(after: .zero)
        }
    }

    private var dayKey: String {
        let components = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func loadBudget() {
        if defaults.string(forKey: BudgetKeys.day) == dayKey {
            requestsToday = defaults.integer(forKey: BudgetKeys.requests)
            tokensToday = defaults.integer(forKey: BudgetKeys.tokens)
        }
    }

    private func rollBudgetDayIfNeeded() {
        guard defaults.string(forKey: BudgetKeys.day) != dayKey else { return }
        requestsToday = 0
        tokensToday = 0
        saveBudget()
        for dataset in Dataset.allCases {
            if case .budgetReached = states[dataset] ?? .idle { states[dataset] = .idle }
        }
    }

    private func recordUsage(requests: Int, tokens: Int) {
        rollBudgetDayIfNeeded()
        requestsToday += requests
        tokensToday += tokens
        saveBudget()
    }

    private func saveBudget() {
        defaults.set(dayKey, forKey: BudgetKeys.day)
        defaults.set(requestsToday, forKey: BudgetKeys.requests)
        defaults.set(tokensToday, forKey: BudgetKeys.tokens)
    }

    private enum BudgetKeys {
        static let day = "analysisBudget.day"
        static let requests = "analysisBudget.requests"
        static let tokens = "analysisBudget.tokens"
    }
}
