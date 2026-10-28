import AppKit
import Charts
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let navigation: DashboardNavigation

    var body: some View {
        let stats = model.insights.stats

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatCard(title: "Transcripts", value: stats.transcriptCount.formatted())
                    StatCard(title: "Dictated words", value: stats.totalWords.formatted())
                    StatCard(title: "Recording time", value: Formatters.duration(stats.totalDuration))
                    StatCard(
                        title: "Words per minute",
                        value: stats.wordsPerMinute.map { String(format: "%.0f", $0) } ?? "–",
                        caption: "Dictated words ÷ recording time"
                    )
                }

                GroupBox("Daily usage, last \(InsightsModel.chartDays) days") {
                    Chart(stats.daily) { day in
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Transcripts", day.transcripts)
                        )
                        .foregroundStyle(.tint)
                    }
                    .chartYAxisLabel("Transcripts")
                    .frame(height: 180)
                    .padding(8)
                }

                GroupRingsSection(model: model, navigation: navigation)

                GroupBox("Frequent words (common English words left out)") {
                    if stats.topWords.isEmpty {
                        Text("No words yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        WordList(words: stats.topWords)
                            .padding(8)
                    }
                }

                if model.selectedDataset == .real, let timings = model.coordinator.lastTimings {
                    Text("Last dictation: text ready \(Formatters.shortDuration(timings.releaseToFinal)) after release, paste sent after \(Formatters.shortDuration(timings.releaseToPaste)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var caption: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            // Keeps the values on the same line whether or not a card has a caption.
            Text(caption ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WordList: View {
    let words: [WordFrequency]

    var body: some View {
        let maxCount = max(words.first?.count ?? 1, 1)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(words) { word in
                HStack(spacing: 8) {
                    Text(word.word)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.tint.opacity(0.6))
                            .frame(width: max(4, proxy.size.width * CGFloat(word.count) / CGFloat(maxCount)))
                    }
                    .frame(height: 8)
                    Text("\(word.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }
}


/// Categorical colors for groups, in fixed slot order. Light and dark are
/// separate steps of the same hues, checked for color-blind separation.
enum GroupPalette {
    private static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5), // blue
        (0xeb6834, 0xd95926), // orange
        (0x1baf7a, 0x199e70), // aqua
        (0xeda100, 0xc98500), // yellow
        (0xe87ba4, 0xd55181), // magenta
        (0x008300, 0x008300), // green
        (0x6250d6, 0x9085e9), // violet
        (0xe34948, 0xe66767), // red
    ]

    static func color(slot: Int) -> Color {
        let pair = slots[slot % slots.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? pair.dark : pair.light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

struct GroupRingsSection: View {
    let model: AppModel
    let navigation: DashboardNavigation

    var body: some View {
        let insights = model.insights
        let analyzed = insights.coverage.analyzed

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Groups by meaning").font(.headline)
                    if model.selectedDataset == .sample { SampleBadge() }
                    Spacer()
                    Button("Open Usage") { navigation.tab = .usage }
                        .buttonStyle(.link)
                }
                if insights.overviewGroups.isEmpty {
                    Text(model.preferences.isAnalysisEnabled(for: model.selectedDataset)
                        ? "No groups yet. They appear here after the first batch is analyzed."
                        : "Turn on analysis in Usage to see groups.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Share of the \(analyzed) analyzed dictations in each group. One dictation can belong to several groups, so the shares add up to more than 100%.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // One column per ring so they spread across the whole
                    // pane. An adaptive grid would make more columns than
                    // rings and leave the row bunched on the left.
                    let count = insights.overviewGroups.count
                    ViewThatFits(in: .horizontal) {
                        ForEach([count, 4, 2].filter { $0 <= count }, id: \.self) { columns in
                            ringGrid(columns: columns)
                        }
                    }
                    if insights.groups.count > insights.overviewGroups.count {
                        Text("Showing the \(insights.overviewGroups.count) largest of \(insights.groups.count) groups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func ringGrid(columns: Int) -> some View {
        let insights = model.insights
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: columns),
            spacing: 12
        ) {
            ForEach(insights.overviewGroups) { group in
                GroupRing(
                    group: group,
                    analyzed: insights.coverage.analyzed,
                    color: GroupPalette.color(slot: insights.groupColorSlots[group.id] ?? 0)
                ) {
                    navigation.showGroup(group.id)
                }
            }
        }
    }
}

struct GroupRing: View {
    let group: GroupSummary
    let analyzed: Int
    let color: Color
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let fraction = min(1, Double(group.sourceCount) / Double(max(analyzed, 1)))

        Button(action: open) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 84, height: 84)
                .padding(.top, 4)

                Text(group.label)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                Text("\(group.sourceCount) \(group.sourceCount == 1 ? "dictation" : "dictations")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(.quaternary.opacity(hovering ? 0.8 : 0.4), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("\(group.summary)\n\nClick to show in Usage.")
        .accessibilityLabel("\(group.label), \(group.sourceCount) dictations. Show in Usage.")
    }
}
