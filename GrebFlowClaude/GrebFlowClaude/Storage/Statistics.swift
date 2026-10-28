import Foundation
import NaturalLanguage

enum WordCounter {
    static func words(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
    }

    static func count(_ text: String) -> Int {
        words(in: text).count
    }
}

struct DailyUsage: Identifiable, Equatable, Sendable {
    var day: Date
    var transcripts: Int
    var words: Int
    var id: Date { day }
}

struct WordFrequency: Identifiable, Equatable, Sendable {
    var word: String
    var count: Int
    var id: String { word }
}

struct UsageStats: Equatable, Sendable {
    var transcriptCount = 0
    var totalWords = 0
    var totalDuration: Double = 0
    var daily: [DailyUsage] = []
    var topWords: [WordFrequency] = []

    /// Dictated words divided by recording duration. Not a typing-speed or
    /// time-saved figure.
    var wordsPerMinute: Double? {
        guard totalDuration > 0 else { return nil }
        return Double(totalWords) / (totalDuration / 60)
    }

    static func compute(
        from transcripts: [TranscriptSnapshot],
        now: Date,
        days: Int,
        calendar: Calendar = .current,
        topWordLimit: Int = 15
    ) -> UsageStats {
        var stats = UsageStats()
        stats.transcriptCount = transcripts.count
        stats.totalWords = transcripts.reduce(0) { $0 + $1.wordCount }
        stats.totalDuration = transcripts.reduce(0) { $0 + $1.durationSeconds }

        // Group by local calendar day.
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: DailyUsage] = [:]
        for offset in 0..<max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            buckets[day] = DailyUsage(day: day, transcripts: 0, words: 0)
        }
        for transcript in transcripts {
            let day = calendar.startOfDay(for: transcript.startedAt)
            guard var bucket = buckets[day] else { continue }
            bucket.transcripts += 1
            bucket.words += transcript.wordCount
            buckets[day] = bucket
        }
        stats.daily = buckets.values.sorted { $0.day < $1.day }

        var counts: [String: Int] = [:]
        for transcript in transcripts {
            for word in WordCounter.words(in: transcript.text) {
                let normalized = word.lowercased()
                guard normalized.count > 1,
                      normalized.contains(where: \.isLetter),
                      !StopWords.english.contains(normalized)
                else { continue }
                counts[normalized, default: 0] += 1
            }
        }
        stats.topWords = counts
            .map { WordFrequency(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
            .prefix(topWordLimit)
            .map { $0 }
        return stats
    }
}

/// Common English function words plus a few spoken fillers. Developer terms
/// (test, PR, review, SwiftUI...) are deliberately not here.
enum StopWords {
    static let english: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "also", "am", "an", "and", "any",
        "are", "aren't", "as", "at", "be", "because", "been", "before", "being", "below", "between",
        "both", "but", "by", "can", "can't", "cannot", "could", "couldn't", "did", "didn't", "do",
        "does", "doesn't", "doing", "don't", "down", "during", "each", "even", "every", "few", "for",
        "from", "further", "get", "gets", "go", "going", "gonna", "got", "had", "hadn't", "has",
        "hasn't", "have", "haven't", "having", "he", "her", "here", "hers", "herself", "him",
        "himself", "his", "how", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "into", "is",
        "isn't", "it", "it's", "its", "itself", "just", "let", "let's", "like", "me", "might",
        "more", "most", "much", "must", "my", "myself", "need", "no", "nor", "not", "now", "of",
        "off", "ok", "okay", "on", "once", "one", "only", "or", "other", "our", "ours",
        "ourselves", "out", "over", "own", "please", "really", "same", "she", "should",
        "shouldn't", "so", "some", "such", "than", "that", "that's", "the", "their", "theirs",
        "them", "themselves", "then", "there", "there's", "these", "they", "this", "those",
        "through", "to", "too", "uh", "um", "under", "until", "up", "us", "very", "want", "wanna",
        "was", "wasn't", "we", "we're", "were", "weren't", "what", "what's", "when", "where",
        "which", "while", "who", "whom", "why", "will", "with", "won't", "would", "wouldn't",
        "yeah", "yes", "you", "you'd", "you'll", "you're", "you've", "your", "yours", "yourself",
        "yourselves", "s", "t", "re", "ve", "ll", "d", "m",
    ]
}

struct RepeatedText: Identifiable, Equatable, Sendable {
    var text: String
    /// Number of distinct dictations containing it.
    var count: Int
    var id: String { text }
}

/// Counts repeated multiword phrases and whole sentences locally. No AI.
///
/// Normalization, applied the same way everywhere:
/// 1. Lowercase with the POSIX locale and turn curly apostrophes straight.
/// 2. Collapse any run of whitespace to one space and trim the ends.
/// 3. Drop punctuation at the start and end (a trailing period or question
///    mark doesn't make a sentence different).
///
/// Each phrase or sentence counts once per dictation, so one long dictation
/// can't inflate a count by repeating itself.
enum PhraseCounter {
    static let phraseLengths = 2...4
    static let minimumSentenceWords = 3

    static func normalize(_ text: String) -> String {
        let lowered = text
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let collapsed = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { normalize(String(text[$0])) }
            .filter { $0.split(separator: " ").count >= minimumSentenceWords }
    }

    static func repeatedSentences(in transcripts: [TranscriptSnapshot], minimumCount: Int = 2, limit: Int = 15) -> [RepeatedText] {
        var counts: [String: Int] = [:]
        for transcript in transcripts {
            for sentence in Set(sentences(in: transcript.text)) {
                counts[sentence, default: 0] += 1
            }
        }
        return ranked(counts, minimumCount: minimumCount, limit: limit)
    }

    /// Phrases of two to four words that don't start or end with a stop
    /// word. A shorter phrase is hidden when a longer one containing it is
    /// just as frequent, so "conventional commit" doesn't crowd out
    /// "conventional commit message".
    static func repeatedPhrases(in transcripts: [TranscriptSnapshot], minimumCount: Int = 2, limit: Int = 15) -> [RepeatedText] {
        var counts: [String: Int] = [:]
        for transcript in transcripts {
            let words = WordCounter.words(in: transcript.text).map(normalize).filter { !$0.isEmpty }
            var phrases = Set<String>()
            for length in phraseLengths where words.count >= length {
                for start in 0...(words.count - length) {
                    let slice = words[start..<(start + length)]
                    guard let first = slice.first, let last = slice.last,
                          !StopWords.english.contains(first), !StopWords.english.contains(last)
                    else { continue }
                    phrases.insert(slice.joined(separator: " "))
                }
            }
            for phrase in phrases { counts[phrase, default: 0] += 1 }
        }

        let frequent = counts.filter { $0.value >= minimumCount }
        let kept = frequent.filter { phrase, count in
            !frequent.contains { other, otherCount in
                other != phrase && otherCount >= count && " \(other) ".contains(" \(phrase) ")
            }
        }
        return ranked(kept, minimumCount: minimumCount, limit: limit)
    }

    private static func ranked(_ counts: [String: Int], minimumCount: Int, limit: Int) -> [RepeatedText] {
        counts
            .filter { $0.value >= minimumCount }
            .map { RepeatedText(text: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                let lhsWords = $0.text.split(separator: " ").count
                let rhsWords = $1.text.split(separator: " ").count
                if lhsWords != rhsWords { return lhsWords > rhsWords }
                return $0.text < $1.text
            }
            .prefix(limit)
            .map { $0 }
    }
}
