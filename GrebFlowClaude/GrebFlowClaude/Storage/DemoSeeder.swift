import Foundation

/// Fictional sample history for demos. Project names are made up and there
/// are no real secrets. Times are relative to "now", spread over the last
/// two weeks so the daily chart is full, and the output is deterministic for
/// a given date.
enum DemoSeeder {
    /// Bump when the phrases or schedule change. Existing sample stores are
    /// recreated once on the next launch.
    static let version = 2
    /// Matches the daily usage chart.
    static let days = 14

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
        // Second week: more of the same tasks, worded the way people repeat them
        "Write tests for the shipping cost calculator, include free shipping over the threshold",
        "Add a unit test for the date formatter with Swedish locale",
        "Can you cover the coupon validation with tests, both expired and unknown codes",
        "Write tests for the Fjord API rate limiter",
        "Add a regression test for the double charge bug",
        "Write component tests for the size picker, keyboard navigation too",
        "Test the Packbot label printer fallback when the API times out",
        "Use conventional commits, this one is a fix",
        "Write a commit message for this, conventional format please",
        "Commit with a subject and a body, the body should say why we changed it",
        "Give me a conventional commit message, it's a refactor with no behavior change",
        "Squash these into one commit with a proper subject and body",
        "Commit the test changes separately from the feature change",
        "Write a PR description for the search filters, mention the feature flag",
        "Draft a pull request description with a summary and screenshots section",
        "Write the PR text for the Nordlys checkout redesign, list the follow ups",
        "Summarize this branch as a PR description for the reviewers",
        "Review my diff before I open the PR",
        "Review the changes in the payment adapter, especially the error mapping",
        "Look over this branch for anything that could break the mobile layout",
        "Check the SQL migration for missing indexes",
        "Review the Packbot retry change, is the backoff capped",
        "Explain what this generic type in the API client does",
        "Explain how the feature flags are loaded at startup",
        "Walk me through the Nordlys auth flow from login to refresh token",
        "Why does this test pass locally but fail in CI",
        "Explain the difference between these two caching strategies in the Fjord API",
        "We use pnpm in this repo, please don't run npm install",
        "Remember to run lint and the type check before you finish",
        "Use the design tokens, not raw colors",
        "Put new components in the features folder and add a story",
        "Don't edit the generated client, update the OpenAPI spec",
        "Keep the diff small and don't reformat unrelated files",
        "Run the tests, then write a conventional commit message",
        "Review the changes and draft a PR description for them",
        "Add tests for the coupon service and commit with a subject and body",
        "Explain the failing test and suggest a fix",
        // Debugging
        "Why is the product list rendering twice on page load",
        "Find out why the Fjord API returns a 500 on empty carts",
        "The checkout button stays disabled after the address is filled in, find the bug",
        "Debug the memory leak in the image carousel",
        "Figure out why the webhook signature check fails on staging",
        "Why is the build so slow since we added the icon package",
        "Track down where this undefined price comes from",
        // Refactoring
        "Refactor the order service into smaller functions, keep behavior the same",
        "Extract the price formatting into a shared helper",
        "Move the cart logic out of the component into a hook",
        "Replace the nested ifs in the shipping rules with a lookup table",
        "Split this file, it's over a thousand lines",
        // More unrelated requests
        "Add aria labels to the icon buttons in the header",
        "What's the keyboard shortcut for multi cursor in VS Code",
        "Generate a dot env example file from the config schema",
        "Write a regex that matches Swedish postal codes",
        "Set up a GitHub Action that runs the tests on pull requests",
        "Change the toast duration to five seconds",
        "Add a dark mode variant for the footer",
        "Make the date picker start weeks on Monday",
    ]

    static func drafts(now: Date, calendar: Calendar = .current) -> [TranscriptDraft] {
        var generator = SeededGenerator(seed: UInt64(calendar.startOfDay(for: now).timeIntervalSince1970))
        let today = calendar.startOfDay(for: now)
        let perDay = dailyCounts(today: today, total: phrases.count, calendar: calendar)
        // A fixed seed mixes the topics across days the same way every time,
        // so one day isn't all tests and the next all commits.
        var shuffler = SeededGenerator(seed: 2026)
        let order = phrases.indices.shuffled(using: &shuffler)
        let dayOffsets = perDay.enumerated().flatMap { offset, count in Array(repeating: offset, count: count) }

        return zip(order, dayOffsets).enumerated().compactMap { position, pair in
            let (index, dayOffset) = pair
            let phrase = phrases[index]
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { return nil }
            let minutes = 8 * 60 + Int(generator.next() % (9 * 60))
            var startedAt = day.addingTimeInterval(TimeInterval(minutes * 60 + Int(generator.next() % 60)))
            if startedAt >= now {
                startedAt = now.addingTimeInterval(-TimeInterval(600 + position * 60))
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

    /// How many dictations land on each day, index 0 being today. Weekends
    /// are quiet, use grows a little over the two weeks, and today is only
    /// half a day. Every day gets at least one so the chart has no gaps.
    static func dailyCounts(today: Date, total: Int, calendar: Calendar = .current) -> [Int] {
        let weights = (0..<days).map { offset -> Double in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return 1 }
            var weight = calendar.isDateInWeekend(day) ? 0.25 : 1
            weight *= 0.7 + 0.3 * Double(days - 1 - offset) / Double(days - 1)
            if offset == 0 { weight *= 0.5 }
            return weight
        }
        let spare = max(total - days, 0)
        let sum = weights.reduce(0, +)
        let exact = weights.map { Double(spare) * $0 / sum }
        var counts = exact.map { 1 + Int($0) }
        // Largest remainder, so the counts add up to exactly `total`.
        let leftover = max(total - counts.reduce(0, +), 0)
        let byRemainder = exact.indices.sorted { exact[$0] - exact[$0].rounded(.down) > exact[$1] - exact[$1].rounded(.down) }
        for index in byRemainder.prefix(leftover) { counts[index] += 1 }
        return counts
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
