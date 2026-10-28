import Foundation

struct TranscriptSegment: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
}

/// Builds one transcript from progressive recognizer output.
///
/// Volatile results replace the previous volatile text instead of being
/// appended. A finalized result is stored by its audio range, so a revised
/// result for the same range replaces the earlier one rather than adding a
/// second copy.
struct TranscriptAssembler: Sendable {
    private var finals: [Int64: TranscriptSegment] = [:]
    private var volatile: TranscriptSegment?

    mutating func apply(_ segment: TranscriptSegment) {
        if segment.isFinal {
            finals = finals.filter { _, existing in
                !(existing.start >= segment.start && existing.end <= segment.end)
            }
            finals[Self.key(segment.start)] = segment
            if let current = volatile, current.start < segment.end {
                volatile = nil
            }
        } else {
            volatile = segment
        }
    }

    /// Only finalized text. Used for the committed transcript.
    var finalText: String {
        Self.join(finals.values.sorted { $0.start < $1.start })
    }

    /// Finalized text plus the current volatile tail, for live display.
    var displayText: String {
        var segments = finals.values.sorted { $0.start < $1.start }
        if let volatile { segments.append(volatile) }
        return Self.join(segments)
    }

    var hasVolatileText: Bool { volatile != nil }

    private static func key(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }

    private static func join(_ segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
