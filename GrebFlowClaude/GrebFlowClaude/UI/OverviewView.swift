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
                        .foregroundStyle(Theme.barGradient)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius, topTrailingRadius: Theme.cornerRadius))
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Theme.border)
                            AxisValueLabel().foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Theme.border)
                            AxisValueLabel().foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .chartYAxisLabel {
                        Text("Transcripts").foregroundStyle(Theme.textSecondary)
                    }
                    .frame(height: 180)
                }

                GroupRingsSection(model: model, navigation: navigation)

                GroupBox("Frequent words (common English words left out)") {
                    if stats.topWords.isEmpty {
                        Text("No words yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        WordList(words: stats.topWords)
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
                .sectionLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 56, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            // Keeps the values on the same line whether or not a card has a caption.
            Text(caption ?? " ")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(14)
        .themedCard()
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
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.meterGradient)
                                .frame(width: max(4, proxy.size.width * CGFloat(word.count) / CGFloat(maxCount)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(word.count)")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
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
                    Text("Groups by meaning").sectionLabel()
                    if model.selectedDataset == .sample { SampleBadge() }
                    Spacer()
                    Button("Open Usage") { navigation.tab = .usage }
                        .buttonStyle(.link)
                }
                if insights.overviewGroups.isEmpty {
                    Text(model.preferences.isAnalysisEnabled(for: model.selectedDataset)
                        ? "No groups yet. They appear here after the first batch is analyzed."
                        : "Turn on analysis in Usage to see groups.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Share of the \(analyzed) analyzed dictations in each group. One dictation can belong to several groups, so the shares add up to more than 100%.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
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
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    color: Theme.shade(rank: insights.groupShadeRanks[group.id] ?? 0)
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
                        .stroke(Theme.track, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                }
                .frame(width: 84, height: 84)
                .padding(.top, 4)

                Text(group.label)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                Text("\(group.sourceCount) \(group.sourceCount == 1 ? "dictation" : "dictations")")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .themedCard(fill: hovering ? Theme.cardHover : Theme.background.opacity(0.5))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("\(group.summary)\n\nClick to show in Usage.")
        .accessibilityLabel("\(group.label), \(group.sourceCount) dictations. Show in Usage.")
    }
}
