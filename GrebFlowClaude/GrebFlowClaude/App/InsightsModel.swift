import Foundation
import Observation

/// Everything the dashboard shows for one dataset, computed outside the
/// views. A redesign can replace every view without touching this.
@MainActor
@Observable
final class InsightsModel {
    private(set) var dataset: Dataset = .real
    /// Newest first.
    private(set) var transcripts: [TranscriptSnapshot] = []
    private(set) var stats = UsageStats()
    private(set) var phrases: [RepeatedText] = []
    private(set) var sentences: [RepeatedText] = []
    private(set) var groups: [GroupSummary] = []
    /// The largest groups, shown as rings on the overview.
    private(set) var overviewGroups: [GroupSummary] = []
    /// Palette slot per overview group. Usage reuses it so a group keeps
    /// its color across both tabs.
    private(set) var groupColorSlots: [UUID: Int] = [:]
    private(set) var coverage = AnalysisCoverage()
    private(set) var loadError: String?

    /// Days shown in the daily usage chart.
    static let chartDays = 14
    /// One per categorical palette color, so no two rings share a color.
    static let overviewGroupLimit = 8

    func refresh(from store: HistoryStore, now: Date = Date()) {
        dataset = store.dataset
        do {
            let all = try store.transcripts()
            transcripts = all.reversed()
            stats = UsageStats.compute(from: all, now: now, days: Self.chartDays)
            phrases = PhraseCounter.repeatedPhrases(in: all)
            sentences = PhraseCounter.repeatedSentences(in: all)
            groups = try store.groupSummaries()
            overviewGroups = Array(groups.prefix(Self.overviewGroupLimit))
            groupColorSlots = Self.colorSlots(for: overviewGroups)
            coverage = try store.coverage()
            loadError = nil
        } catch {
            loadError = "Couldn't read local history: \(error.localizedDescription)"
        }
    }

    /// Slots follow creation order, not rank, so a group doesn't change
    /// color when another one overtakes it in count.
    nonisolated static func colorSlots(for groups: [GroupSummary]) -> [UUID: Int] {
        let ordered = groups.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
    }
}
