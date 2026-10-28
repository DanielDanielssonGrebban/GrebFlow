import Foundation

/// Fictional sample history for demos. Project names are made up and there
/// are no real secrets. Times are relative to "now", spread over the last
/// seven days, and the output is deterministic for a given date.
enum DemoSeeder {
    static let phrases: [String] = [
        // Writing tests
        "Write unit tests for the checkout service in Nordlys, cover the discount edge cases",
        "Add tests for the cart reducer, especially removing the last item",
        "Can you write integration tests for the Fjord API order endpoint",
        "Write a test that reproduces the timezone bug in the booking calendar",
        "Add snapshot tests for the new product card component",
        "Generate test cases for the password reset flow including expired tokens",
        "Please add missing tests for the webhook handler before I refactor it",
        "Cover the inventory sync job with tests, mock the warehouse client",
        "Write a failing test first for the rounding issue in invoice totals",
        "Write end to end tests for signing up and logging in on Nordlys",
        // Commit preparation, worded differently on purpose
        "Use conventional commits for this change",
        "Write a conventional commit message for the staged files",
        "Include a commit subject and body",
        "Commit this with a short subject line and a body that explains why",
        "Make the commit message follow the conventional commit format, feat or fix prefix",
        "Split my changes into small commits with clear messages",
        "Write the commit message, keep the subject under fifty characters",
        // PR descriptions
        "Write a PR description for this branch, it moves the cart to the new state store",
        "Summarize my changes into a pull request description with a testing section",
        "Draft the PR text for the Fjord API pagination change",
        "Prepare a pull request summary for the image lazy loading work",
        "Write the PR description and list what QA should check on staging",
        "Create a PR description for the Packbot shipping label refactor",
        // Reviewing changes
        "Review the diff on this branch and point out risky changes",
        "Look through my changes and check for missing error handling",
        "Review this pull request for performance problems in the product list",
        "Check the Fjord API changes for breaking changes in the response format",
        "Review the migration script before I run it on staging",
        "Review my changes to the auth middleware, I'm worried about token refresh",
        "Do a quick code review of the Packbot webhook retry logic",
        "Check my changes for leftover console logs and debug code",
        // Explaining code
        "Explain how the order state machine works in the Nordlys backend",
        "What does this regex in the address parser actually match",
        "Explain the caching layer in the Fjord API like I'm new to the project",
        "Walk me through how the checkout total is calculated",
        "Explain why this React effect runs twice in development",
        "How does the Packbot queue decide which job runs next",
        // Repeating project instructions
        "Remember we use pnpm in this repo, not npm, and run lint before committing",
        "Follow the Nordlys conventions, components go in the features folder with a story file",
        "Use our design tokens for colors, never hard coded hex values",
        "Run the type check and the unit tests before you say you're done",
        "Don't touch the generated API client, change the OpenAPI spec instead",
        "Keep the PR small and don't reformat files you didn't change",
        "We use pnpm and Vitest here, please don't add Jest",
        // Several intents in one dictation
        "Write tests for the cart total and then use conventional commits when you commit",
        "Review the diff, then write a PR description with a testing section",
        "Fix the failing lint errors and include a commit subject and body",
        "Explain the webhook retry logic and add a test for the backoff",
        "Run the unit tests, and if they pass write a conventional commit message",
        // Unrelated requests
        "Rename the variable data to orderSummary in this file",
        "Convert this callback function to async await",
        "What's a good name for a hook that tracks scroll position",
        "Find where we set the session cookie expiry",
        "Update the README with the new environment variables",
        "Make the header sticky on mobile and keep the logo centered",
        "Write a SQL query that counts orders per day for the last month",
        "Add a loading skeleton to the product page",
        "Bump the date library and check for breaking changes",
        "Translate these error messages to Swedish",
        "What time zone does the staging server use",
    ]

    static func drafts(now: Date, calendar: Calendar = .current) -> [TranscriptDraft] {
        var generator = SeededGenerator(seed: UInt64(calendar.startOfDay(for: now).timeIntervalSince1970))
        let today = calendar.startOfDay(for: now)
        return phrases.enumerated().compactMap { index, phrase in
            let dayOffset = index % 7
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { return nil }
            let minutes = 8 * 60 + Int(generator.next() % (9 * 60))
            var startedAt = day.addingTimeInterval(TimeInterval(minutes * 60 + Int(generator.next() % 60)))
            if startedAt >= now {
                startedAt = now.addingTimeInterval(-TimeInterval(600 + index * 60))
            }
            let words = WordCounter.count(phrase)
            let duration = Double(words) / 2.4 + Double(generator.next() % 15) / 10
            return TranscriptDraft(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(duration),
                durationSeconds: duration,
                locale: "en-US",
                text: phrase,
                insertionText: nil,
                wordCount: words,
                destinationBundleID: index.isMultiple(of: 3) ? "com.apple.Terminal" : "com.microsoft.VSCode",
                releaseToFinalSeconds: nil,
                releaseToPasteSeconds: nil,
                outcome: .pasteAttempted
            )
        }
    }

    /// Seeds only an empty store, so calling it twice doesn't duplicate.
    @MainActor
    @discardableResult
    static func seedIfEmpty(_ store: HistoryStore, now: Date) throws -> Bool {
        precondition(store.dataset == .sample, "Sample data only goes in the sample store")
        guard try store.transcriptCount() == 0 else { return false }
        try store.add(drafts(now: now))
        return true
    }

    @MainActor
    static func reset(_ store: HistoryStore, now: Date) throws {
        precondition(store.dataset == .sample, "Sample data only goes in the sample store")
        try store.deleteAll()
        try store.add(drafts(now: now))
    }
}

/// SplitMix64, so sample times are stable for a given day.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
