import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    @Attribute(.unique) var id: UUID
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
    var outcomeRaw: String

    // AI grouping state. A completed analysis may assign no groups.
    var analyzedAt: Date?
    var analysisModelID: String?
    var analysisPromptVersion: String?
    /// Set when a transcript can't be analyzed (for example, too long for
    /// one request). It stays visibly unanalyzed instead of being dropped.
    var analysisBlockedReason: String?

    init(draft: TranscriptDraft) {
        id = draft.id
        startedAt = draft.startedAt
        endedAt = draft.endedAt
        durationSeconds = draft.durationSeconds
        locale = draft.locale
        text = draft.text
        insertionText = draft.insertionText
        wordCount = draft.wordCount
        destinationBundleID = draft.destinationBundleID
        releaseToFinalSeconds = draft.releaseToFinalSeconds
        releaseToPasteSeconds = draft.releaseToPasteSeconds
        outcomeRaw = draft.outcome.rawValue
    }

    var snapshot: TranscriptSnapshot {
        TranscriptSnapshot(
            id: id,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            text: text,
            wordCount: wordCount,
            outcome: PasteOutcome(rawValue: outcomeRaw) ?? .copyOnly,
            isAnalyzed: analyzedAt != nil,
            analysisBlockedReason: analysisBlockedReason
        )
    }
}

/// A semantic group of related requests, labelled by the model.
@Model
final class GroupRecord {
    @Attribute(.unique) var id: UUID
    var label: String
    var summary: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID, label: String, summary: String, createdAt: Date) {
        self.id = id
        self.label = label
        self.summary = summary
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}

/// Links one group to one transcript, once, with the exact excerpts that
/// support it.
@Model
final class MembershipRecord {
    @Attribute(.unique) var key: String
    var groupID: UUID
    var transcriptID: UUID
    var excerpts: [String]

    init(groupID: UUID, transcriptID: UUID, excerpts: [String]) {
        key = Self.key(groupID: groupID, transcriptID: transcriptID)
        self.groupID = groupID
        self.transcriptID = transcriptID
        self.excerpts = excerpts
    }

    static func key(groupID: UUID, transcriptID: UUID) -> String {
        "\(groupID.uuidString)|\(transcriptID.uuidString)"
    }
}

@Model
final class AnalysisBatchRecord {
    @Attribute(.unique) var id: UUID
    var sourceIDs: [UUID]
    var completedAt: Date
    var modelID: String
    var promptVersion: String
    var inputTokens: Int?
    var outputTokens: Int?
    var deletionGeneration: Int

    init(sourceIDs: [UUID], completedAt: Date, modelID: String, promptVersion: String, inputTokens: Int?, outputTokens: Int?, deletionGeneration: Int) {
        id = UUID()
        self.sourceIDs = sourceIDs
        self.completedAt = completedAt
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.deletionGeneration = deletionGeneration
    }
}

/// Plain value copy of a transcript, safe to hand to stats and analysis code.
struct TranscriptSnapshot: Sendable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var durationSeconds: Double
    var text: String
    var wordCount: Int
    var outcome: PasteOutcome
    var isAnalyzed = false
    var analysisBlockedReason: String?
}

struct GroupDefinition: Sendable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var summary: String
}

struct GroupEvidence: Sendable, Equatable, Identifiable {
    var transcriptID: UUID
    var startedAt: Date
    var transcriptText: String
    var excerpts: [String]
    var id: UUID { transcriptID }
}

struct GroupSummary: Sendable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var summary: String
    var updatedAt: Date
    /// Distinct source dictations, counted locally.
    var sourceCount: Int
    var evidence: [GroupEvidence]
}

struct AnalysisCoverage: Sendable, Equatable {
    var total = 0
    var analyzed = 0
    var blocked = 0
    var lastAnalyzedAt: Date?

    var pending: Int { total - analyzed - blocked }
}
