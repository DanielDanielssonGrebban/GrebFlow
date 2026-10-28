import Foundation
import Testing
@testable import GrebFlowClaude

@MainActor
@Suite("History storage and grouping data")
struct HistoryStoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(with texts: [String]) throws -> (HistoryStore, [TranscriptSnapshot]) {
        let store = try HistoryStore.inMemory(.real)
        for (index, text) in texts.enumerated() {
            try store.add(transcript(text, at: now.addingTimeInterval(TimeInterval(index * 60))))
        }
        return (store, try store.transcripts())
    }

    private func batch(_ sources: [TranscriptSnapshot], newGroups: [ValidatedBatch.NewGroup] = [], assignments: [ValidatedBatch.Assignment]) -> ValidatedBatch {
        ValidatedBatch(sourceIDs: sources.map(\.id), newGroups: newGroups, assignments: assignments, modelID: "claude-haiku-5-5", promptVersion: "grouping-v1", inputTokens: 100, outputTokens: 50)
    }

    @Test func historyIsKeptAndChronological() throws {
        let (store, transcripts) = try store(with: ["a", "b", "c"])
        #expect(transcripts.map(\.text) == ["a", "b", "c"])
        #expect(try store.transcriptCount() == 3)
    }

    @Test func applyingABatchSavesGroupsMembershipsAndProgress() throws {
        let (store, transcripts) = try store(with: ["use conventional commits", "write tests", "rename a variable"])
        let commit = ValidatedBatch.NewGroup(id: UUID(), label: "Commit preparation", summary: "Commit messages.")
        let tests = ValidatedBatch.NewGroup(id: UUID(), label: "Writing tests", summary: "Tests.")
        let result = try store.applyBatch(batch(transcripts, newGroups: [commit, tests], assignments: [
            .init(groupID: commit.id, transcriptID: transcripts[0].id, excerpts: ["use conventional commits"]),
            .init(groupID: tests.id, transcriptID: transcripts[1].id, excerpts: ["write tests"]),
        ]), expectedGeneration: store.deletionGeneration, now: now)
        #expect(result == .saved)

        let coverage = try store.coverage()
        #expect(coverage.analyzed == 3)
        #expect(coverage.pending == 0)
        #expect(coverage.lastAnalyzedAt == now)
        #expect(try store.pendingTranscripts(limit: 10).isEmpty)
        #expect(try store.groupSummaries().map(\.label).sorted() == ["Commit preparation", "Writing tests"])
        #expect(try store.groupDefinitions().count == 2)
    }

    @Test func applyingTwiceDoesNotDuplicateMemberships() throws {
        let (store, transcripts) = try store(with: ["use conventional commits"])
        let group = ValidatedBatch.NewGroup(id: UUID(), label: "Commit preparation", summary: "Commits.")
        let validated = batch(transcripts, newGroups: [group], assignments: [
            .init(groupID: group.id, transcriptID: transcripts[0].id, excerpts: ["conventional commits"]),
        ])
        _ = try store.applyBatch(validated, expectedGeneration: 0, now: now)
        _ = try store.applyBatch(validated, expectedGeneration: 0, now: now)
        let summary = try #require(try store.groupSummaries().first)
        #expect(summary.sourceCount == 1)
        #expect(summary.evidence.first?.excerpts == ["conventional commits"])
        #expect(try store.groupDefinitions().count == 1)
    }

    @Test func groupCountsAreDistinctDictationsAndCanOverlap() throws {
        let (store, transcripts) = try store(with: [
            "write tests and use conventional commits",
            "use conventional commits",
            "write tests",
        ])
        let commit = ValidatedBatch.NewGroup(id: UUID(), label: "Commit preparation", summary: "Commits.")
        let tests = ValidatedBatch.NewGroup(id: UUID(), label: "Writing tests", summary: "Tests.")
        _ = try store.applyBatch(batch(transcripts, newGroups: [commit, tests], assignments: [
            .init(groupID: tests.id, transcriptID: transcripts[0].id, excerpts: ["write tests"]),
            .init(groupID: commit.id, transcriptID: transcripts[0].id, excerpts: ["use conventional commits"]),
            .init(groupID: commit.id, transcriptID: transcripts[1].id, excerpts: ["use conventional commits"]),
            .init(groupID: tests.id, transcriptID: transcripts[2].id, excerpts: ["write tests"]),
        ]), expectedGeneration: 0, now: now)

        let summaries = try store.groupSummaries()
        #expect(summaries.map(\.sourceCount) == [2, 2])
        // Three dictations in total, not four: the overlap isn't an exclusive total.
        #expect(Set(summaries.flatMap { $0.evidence.map(\.transcriptID) }).count == 3)
    }

    @Test func emptyAssignmentsStillMarkTranscriptsAnalyzed() throws {
        let (store, transcripts) = try store(with: ["what time is it in staging"])
        _ = try store.applyBatch(batch(transcripts, assignments: []), expectedGeneration: 0, now: now)
        #expect(try store.coverage().analyzed == 1)
        #expect(try store.groupSummaries().isEmpty)
    }

    @Test func lateResponseAfterDeleteAllIsDropped() throws {
        let (store, transcripts) = try store(with: ["use conventional commits"])
        let generation = store.deletionGeneration
        try store.deleteAll()
        try store.add(transcript("new dictation", at: now))
        let group = ValidatedBatch.NewGroup(id: UUID(), label: "Commit preparation", summary: "Commits.")
        let result = try store.applyBatch(batch(transcripts, newGroups: [group], assignments: [
            .init(groupID: group.id, transcriptID: transcripts[0].id, excerpts: ["conventional commits"]),
        ]), expectedGeneration: generation, now: now)
        #expect(result == .historyDeleted)
        #expect(try store.groupSummaries().isEmpty)
        #expect(try store.groupDefinitions().isEmpty)
    }

    @Test func lateResponseAfterSampleResetIsDropped() throws {
        let sample = try HistoryStore.inMemory(.sample)
        try DemoSeeder.seedIfEmpty(sample, now: now)
        let pending = try sample.pendingTranscripts(limit: 5)
        let generation = sample.deletionGeneration
        try DemoSeeder.reset(sample, now: now)
        let result = try sample.applyBatch(batch(pending, assignments: []), expectedGeneration: generation, now: now)
        #expect(result == .historyDeleted)
        #expect(try sample.coverage().analyzed == 0)
    }

    @Test func missingSourcesAreRejected() throws {
        let (store, _) = try store(with: ["one"])
        let ghost = TranscriptSnapshot(id: UUID(), startedAt: now, durationSeconds: 1, text: "gone", wordCount: 1, outcome: .pasteAttempted)
        let result = try store.applyBatch(batch([ghost], assignments: []), expectedGeneration: 0, now: now)
        #expect(result == .sourcesMissing)
    }

    @Test func deleteAllRemovesTranscriptsGroupsAndProgress() throws {
        let (store, transcripts) = try store(with: ["use conventional commits", "write tests"])
        let group = ValidatedBatch.NewGroup(id: UUID(), label: "Commit preparation", summary: "Commits.")
        _ = try store.applyBatch(batch(transcripts, newGroups: [group], assignments: [
            .init(groupID: group.id, transcriptID: transcripts[0].id, excerpts: ["conventional commits"]),
        ]), expectedGeneration: 0, now: now)
        try store.deleteAll()
        #expect(try store.transcriptCount() == 0)
        #expect(try store.groupSummaries().isEmpty)
        #expect(try store.groupDefinitions().isEmpty)
        #expect(try store.coverage() == AnalysisCoverage())
        #expect(store.deletionGeneration == 1)
    }

    @Test func blockedTranscriptsStayVisiblyUnanalyzed() throws {
        let (store, transcripts) = try store(with: ["huge", "small"])
        try store.markBlocked([transcripts[0].id], reason: "Too long")
        let coverage = try store.coverage()
        #expect(coverage.blocked == 1)
        #expect(coverage.pending == 1)
        #expect(try store.pendingTranscripts(limit: 10).map(\.text) == ["small"])
    }

    @Test func realAndSampleStoresAreIsolated() throws {
        let real = try HistoryStore.inMemory(.real)
        let sample = try HistoryStore.inMemory(.sample)
        try real.add(transcript("real one", at: now))
        try DemoSeeder.seedIfEmpty(sample, now: now)
        #expect(try real.transcripts().map(\.text) == ["real one"])
        #expect(try !sample.transcripts().map(\.text).contains("real one"))
        #expect(try sample.transcriptCount() == DemoSeeder.phrases.count)
    }

    @Test func seedingIsIdempotentAndResetDoesNotDuplicate() throws {
        let sample = try HistoryStore.inMemory(.sample)
        #expect(try DemoSeeder.seedIfEmpty(sample, now: now))
        #expect(try !DemoSeeder.seedIfEmpty(sample, now: now))
        try DemoSeeder.reset(sample, now: now)
        try DemoSeeder.reset(sample, now: now)
        #expect(try sample.transcriptCount() == DemoSeeder.phrases.count)
    }

    @Test func sampleDataCoversThePlanExamples() {
        let drafts = DemoSeeder.drafts(now: now)
        let day: TimeInterval = 86_400
        #expect(drafts.count >= 55 && drafts.count <= 65)
        #expect(drafts.allSatisfy { $0.startedAt < now && $0.startedAt > now.addingTimeInterval(-7 * day) })
        let texts = drafts.map { $0.text.lowercased() }
        #expect(texts.contains { $0.contains("use conventional commits") })
        #expect(texts.contains { $0.contains("include a commit subject and body") })
        #expect(drafts.map(\.startedAt) == DemoSeeder.drafts(now: now).map(\.startedAt))
    }
}

@Suite("Statistics")
struct StatisticsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ text: String, at date: Date? = nil, duration: Double = 3) -> TranscriptSnapshot {
        TranscriptSnapshot(id: UUID(), startedAt: date ?? now, durationSeconds: duration, text: text, wordCount: WordCounter.count(text), outcome: .pasteAttempted)
    }

    @Test func wordsPerMinuteIsWordsOverRecordingTime() {
        let stats = UsageStats.compute(from: [
            snapshot("one two three four five six"),
            snapshot("seven eight nine ten eleven twelve"),
        ], now: now, days: 7)
        #expect(stats.totalWords == 12)
        #expect(stats.wordsPerMinute == 120)
    }

    @Test func frequentWordsSkipStopWordsButKeepDeveloperTerms() {
        let stats = UsageStats.compute(from: [
            snapshot("Please write the tests for the SwiftUI view"),
            snapshot("Write a PR description and the tests"),
            snapshot("Review the GitHub PR"),
        ], now: now, days: 7)
        let words = stats.topWords.map(\.word)
        #expect(words.prefix(3).contains("tests"))
        #expect(words.contains("swiftui"))
        #expect(words.contains("github"))
        #expect(!words.contains("the"))
    }

    @Test func frequentWordsStopAtFifteen() {
        let words = (1...20).map { "word\($0)" }.joined(separator: " ")
        let stats = UsageStats.compute(from: [snapshot(words)], now: now, days: 7)
        #expect(stats.topWords.count == 15)
    }

    @Test func dailyUsageGroupsByLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let today = calendar.startOfDay(for: now)
        let stats = UsageStats.compute(from: [
            snapshot("a", at: today.addingTimeInterval(60)),
            snapshot("b", at: today.addingTimeInterval(-60)),
            snapshot("c", at: today.addingTimeInterval(-120)),
        ], now: now, days: 7, calendar: calendar)
        #expect(stats.daily.count == 7)
        #expect(stats.daily.last?.transcripts == 1)
        #expect(stats.daily.dropLast().last?.transcripts == 2)
    }

    @Test func normalizationIsDeterministic() {
        #expect(PhraseCounter.normalize("  Use   Conventional\nCommits! ") == "use conventional commits")
        #expect(PhraseCounter.normalize("Don\u{2019}t touch it.") == "don't touch it")
    }

    @Test func repeatedSentencesIgnoreCaseWhitespaceAndEndPunctuation() {
        let sentences = PhraseCounter.repeatedSentences(in: [
            snapshot("Run the unit tests. Then commit."),
            snapshot("run the  unit tests!"),
            snapshot("Something else entirely here."),
        ])
        #expect(sentences == [RepeatedText(text: "run the unit tests", count: 2)])
    }

    @Test func repeatedPhrasesCountOncePerDictationAndPreferLonger() {
        let phrases = PhraseCounter.repeatedPhrases(in: [
            snapshot("write a conventional commit message, a conventional commit message please"),
            snapshot("Conventional commit message for the staged files"),
            snapshot("unrelated words only"),
        ])
        #expect(phrases.first == RepeatedText(text: "conventional commit message", count: 2))
        // Subsumed by the longer phrase with the same count.
        #expect(!phrases.contains { $0.text == "conventional commit" })
        #expect(!phrases.contains { $0.text == "commit message" })
        #expect(phrases == PhraseCounter.repeatedPhrases(in: [
            snapshot("write a conventional commit message, a conventional commit message please"),
            snapshot("Conventional commit message for the staged files"),
            snapshot("unrelated words only"),
        ]))
    }
}
