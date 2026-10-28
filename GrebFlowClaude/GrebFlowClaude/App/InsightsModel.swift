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
    private(set) var coverage = AnalysisCoverage()
    private(set) var loadError: String?

    /// Days shown in the daily usage chart.
    static let chartDays = 14

    func refresh(from store: HistoryStore, now: Date = Date()) {
        dataset = store.dataset
        do {
            let all = try store.transcripts()
            transcripts = all.reversed()
            stats = UsageStats.compute(from: all, now: now, days: Self.chartDays)
            phrases = PhraseCounter.repeatedPhrases(in: all)
            sentences = PhraseCounter.repeatedSentences(in: all)
            groups = try store.groupSummaries()
            coverage = try store.coverage()
            loadError = nil
        } catch {
            loadError = "Couldn't read local history: \(error.localizedDescription)"
        }
    }
}
