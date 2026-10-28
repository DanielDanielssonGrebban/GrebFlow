import Charts
import SwiftUI

struct OverviewView: View {
    let model: AppModel

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
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
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
