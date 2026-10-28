import Foundation

/// Words the recognizer should lean toward, passed to the analyzer as
/// contextual strings. Hints raise the odds of a word but don't force it.
///
/// Only list words the stock English model gets wrong: homophones like
/// JSON/Jason, odd spellings, and our own names. Ordinary words ("commit",
/// "function") are already recognized, and every extra entry weakens the
/// rest. Apple recommends staying under 100. The spelling here is the
/// spelling that gets pasted.
enum DeveloperVocabulary {
    static let maxTerms = 100

    static let terms: [String] = [
        // Our names
        "GrebFlow",
        "Grebban",
        "Claude",

        // Formats and languages
        "JSON",
        "YAML",
        "TypeScript",
        "JavaScript",
        "GraphQL",
        "SQL",
        "PostgreSQL",
        "regex",

        // Code words that sound like something else
        "enum",
        "async",
        "await",
        "localhost",
        "README",

        // Tools and frameworks
        "npm",
        "pnpm",
        "npx",
        "Xcode",
        "SwiftUI",
        "SwiftData",
        "Vite",
        "Next.js",
        "Tailwind",
        "ESLint",
        "webpack",
        "nginx",
        "kubectl",
        "Kubernetes",

        // Auth
        "OAuth",
        "JWT",
    ]
}
