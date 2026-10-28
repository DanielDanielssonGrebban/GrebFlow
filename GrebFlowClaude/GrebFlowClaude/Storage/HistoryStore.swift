import Foundation
import SwiftData

/// A validated grouping result, ready to save. Built by the analysis code.
struct ValidatedBatch: Sendable, Equatable {
    struct NewGroup: Sendable, Equatable {
        var id: UUID
        var label: String
        var summary: String
    }

    struct Assignment: Sendable, Equatable {
        var groupID: UUID
        var transcriptID: UUID
        var excerpts: [String]
    }

    var sourceIDs: [UUID]
    var newGroups: [NewGroup]
    var assignments: [Assignment]
    var modelID: String
    var promptVersion: String
    var inputTokens: Int?
    var outputTokens: Int?
}

/// One SwiftData store per dataset. Real and sample history never share a
/// container, so a query or analysis batch can't mix them.
@MainActor
final class HistoryStore {
    let dataset: Dataset
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Bumped by Delete all history and sample reset. An analysis request
    /// snapshots it, and its response is only saved if it hasn't changed.
    private(set) var deletionGeneration = 0

    init(dataset: Dataset, container: ModelContainer) {
        self.dataset = dataset
        self.container = container
    }

    static let schema = Schema([TranscriptRecord.self, GroupRecord.self, MembershipRecord.self, AnalysisBatchRecord.self])

    /// Uses an explicit file URL so the store never lands in the shared
    /// Application Support root that the other variants also use.
    static func makeContainer(for dataset: Dataset, directory: URL?) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(
                dataset.rawValue,
                schema: schema,
                url: directory.appending(path: "\(dataset.rawValue).store"),
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "\(dataset.rawValue)-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    static func inMemory(_ dataset: Dataset) throws -> HistoryStore {
        HistoryStore(dataset: dataset, container: try makeContainer(for: dataset, directory: nil))
    }

    // MARK: Transcripts

    func add(_ draft: TranscriptDraft) throws {
        context.insert(TranscriptRecord(draft: draft))
        try context.save()
    }

    func add(_ drafts: [TranscriptDraft]) throws {
        for draft in drafts { context.insert(TranscriptRecord(draft: draft)) }
        try context.save()
    }

    /// All transcripts, oldest first.
    func transcripts() throws -> [TranscriptSnapshot] {
        try context.fetch(FetchDescriptor<TranscriptRecord>(sortBy: [SortDescriptor(\.startedAt)])).map(\.snapshot)
    }

    func transcriptCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<TranscriptRecord>())
    }

    // MARK: Analysis input

    /// Transcripts that haven't been analyzed or blocked yet, oldest first.
    func pendingTranscripts(limit: Int) throws -> [TranscriptSnapshot] {
        var descriptor = FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.analyzedAt == nil && $0.analysisBlockedReason == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(\.snapshot)
    }

    func pendingCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.analyzedAt == nil && $0.analysisBlockedReason == nil }
        ))
    }

    func groupDefinitions() throws -> [GroupDefinition] {
        try context.fetch(FetchDescriptor<GroupRecord>(sortBy: [SortDescriptor(\.createdAt)]))
            .map { GroupDefinition(id: $0.id, label: $0.label, summary: $0.summary) }
    }

    func markBlocked(_ ids: [UUID], reason: String) throws {
        let records = try context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { ids.contains($0.id) }))
        for record in records { record.analysisBlockedReason = reason }
        try context.save()
    }

    func coverage() throws -> AnalysisCoverage {
        let total = try transcriptCount()
        let analyzed = try context.fetchCount(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.analyzedAt != nil }))
        let blocked = try context.fetchCount(FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.analyzedAt == nil && $0.analysisBlockedReason != nil }
        ))
        var latest = FetchDescriptor<AnalysisBatchRecord>(sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        latest.fetchLimit = 1
        let last = try context.fetch(latest).first?.completedAt
        return AnalysisCoverage(total: total, analyzed: analyzed, blocked: blocked, lastAnalyzedAt: last)
    }

    // MARK: Groups

    /// Groups ranked by how many distinct dictations support them. Counts
    /// come from stored memberships, never from the model.
    func groupSummaries() throws -> [GroupSummary] {
        let groups = try context.fetch(FetchDescriptor<GroupRecord>())
        let memberships = try context.fetch(FetchDescriptor<MembershipRecord>())
        let transcripts = Dictionary(
            try context.fetch(FetchDescriptor<TranscriptRecord>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let byGroup = Dictionary(grouping: memberships, by: \.groupID)

        return groups.compactMap { group -> GroupSummary? in
            var seen = Set<UUID>()
            let evidence = (byGroup[group.id] ?? []).compactMap { membership -> GroupEvidence? in
                guard let transcript = transcripts[membership.transcriptID], seen.insert(transcript.id).inserted else { return nil }
                return GroupEvidence(
                    transcriptID: transcript.id,
                    startedAt: transcript.startedAt,
                    transcriptText: transcript.text,
                    excerpts: membership.excerpts
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
            guard !evidence.isEmpty else { return nil }
            return GroupSummary(
                id: group.id, label: group.label, summary: group.summary,
                createdAt: group.createdAt, updatedAt: group.updatedAt, sourceCount: evidence.count, evidence: evidence
            )
        }
        .sorted { $0.sourceCount != $1.sourceCount ? $0.sourceCount > $1.sourceCount : $0.label < $1.label }
    }

    enum ApplyResult: Equatable {
        case saved
        case historyDeleted
        case sourcesMissing
    }

    /// Saves a validated batch in one transaction: new groups, memberships,
    /// analysis state, and batch metadata. Rechecks deletion generation and
    /// source existence first so a late response can't recreate deleted
    /// content. Saving twice doesn't duplicate memberships.
    func applyBatch(_ batch: ValidatedBatch, expectedGeneration: Int, now: Date) throws -> ApplyResult {
        guard expectedGeneration == deletionGeneration else { return .historyDeleted }
        let ids = batch.sourceIDs
        let sources = try context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { ids.contains($0.id) }))
        guard sources.count == Set(ids).count else { return .sourcesMissing }

        do {
            var groups = Dictionary(
                try context.fetch(FetchDescriptor<GroupRecord>()).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for proposed in batch.newGroups where groups[proposed.id] == nil {
                let group = GroupRecord(id: proposed.id, label: proposed.label, summary: proposed.summary, createdAt: now)
                context.insert(group)
                groups[proposed.id] = group
            }

            for assignment in batch.assignments {
                guard let group = groups[assignment.groupID] else { continue }
                let key = MembershipRecord.key(groupID: assignment.groupID, transcriptID: assignment.transcriptID)
                let existing = try context.fetch(FetchDescriptor<MembershipRecord>(predicate: #Predicate { $0.key == key })).first
                if let existing {
                    for excerpt in assignment.excerpts where !existing.excerpts.contains(excerpt) {
                        existing.excerpts.append(excerpt)
                    }
                } else {
                    context.insert(MembershipRecord(groupID: assignment.groupID, transcriptID: assignment.transcriptID, excerpts: assignment.excerpts))
                }
                group.updatedAt = now
            }

            for source in sources {
                source.analyzedAt = now
                source.analysisModelID = batch.modelID
                source.analysisPromptVersion = batch.promptVersion
            }

            context.insert(AnalysisBatchRecord(
                sourceIDs: ids, completedAt: now, modelID: batch.modelID, promptVersion: batch.promptVersion,
                inputTokens: batch.inputTokens, outputTokens: batch.outputTokens, deletionGeneration: deletionGeneration
            ))
            try context.save()
        } catch {
            // Keep the work pending rather than half-saved.
            context.rollback()
            throw error
        }
        return .saved
    }

    // MARK: Deletion

    /// Removes transcripts and everything derived from them: groups,
    /// memberships, and analysis progress.
    func deleteAll() throws {
        deletionGeneration += 1
        try context.delete(model: MembershipRecord.self)
        try context.delete(model: GroupRecord.self)
        try context.delete(model: AnalysisBatchRecord.self)
        try context.delete(model: TranscriptRecord.self)
        try context.save()
    }
}
