import SwiftUI

struct UsageView: View {
    let model: AppModel
    let navigation: DashboardNavigation
    @State private var confirmEnable = false
    @State private var expandedGroups: Set<UUID> = []
    @State private var highlightedGroup: UUID?

    var body: some View {
        let insights = model.insights
        let dataset = model.selectedDataset

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AnalysisStatusBox(model: model, dataset: dataset, coverage: insights.coverage) {
                        confirmEnable = true
                    }

                    HStack(alignment: .top, spacing: 16) {
                        RepeatedList(
                            title: "Repeated phrases",
                            caption: "Two to four words, counted once per dictation.",
                            items: insights.phrases
                        )
                        RepeatedList(
                            title: "Repeated sentences",
                            caption: "Whole sentences after lowercasing and trimming punctuation.",
                            items: insights.sentences
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Groups by meaning").font(.title3.weight(.semibold))
                            if dataset == .sample { SampleBadge() }
                        }
                        Text("Grouped by Claude. Counts are distinct dictations, counted on this Mac. One dictation can belong to several groups, so the counts overlap.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if insights.groups.isEmpty {
                            Text(model.preferences.isAnalysisEnabled(for: dataset)
                                ? "No groups yet. They appear here after the first batch is analyzed."
                                : "Turn on analysis for this dataset to see groups.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(insights.groups) { group in
                                GroupCard(
                                    group: group,
                                    color: insights.groupColorSlots[group.id].map { GroupPalette.color(slot: $0) },
                                    isHighlighted: highlightedGroup == group.id,
                                    isExpanded: Binding(
                                        get: { expandedGroups.contains(group.id) },
                                        set: { if $0 { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) } }
                                    )
                                )
                                .id(group.id)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .task(id: navigation.focusedGroupID) {
                await focusGroup(using: proxy)
            }
        }
        .confirmationDialog("Turn on automatic grouping for \(dataset.label.lowercased())?", isPresented: $confirmEnable) {
            Button("Turn on") { model.setAnalysisEnabled(true, for: dataset) }
        } message: {
            Text(AnalysisConsent.explanation(dataset: dataset, modelID: model.preferences.modelID))
        }
    }
}

extension UsageView {
    /// Opens the group picked on the overview: expand it, scroll it to the
    /// top, and flash its border so it's easy to spot.
    private func focusGroup(using proxy: ScrollViewProxy) async {
        guard let id = navigation.focusedGroupID else { return }
        navigation.focusedGroupID = nil
        guard model.insights.groups.contains(where: { $0.id == id }) else { return }
        expandedGroups.insert(id)
        highlightedGroup = id
        // Let the expanded card lay out before scrolling to it.
        await Task.yield()
        withAnimation { proxy.scrollTo(id, anchor: .top) }
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { if highlightedGroup == id { highlightedGroup = nil } }
    }
}

enum AnalysisConsent {
    static func explanation(dataset: Dataset, modelID: String) -> String {
        "GrebFlowClaude will send this dataset's unanalyzed transcripts, and new ones as they arrive, to Anthropic in small batches using your API key and \(modelID). This costs API credits. It keeps running while GrebFlowClaude is open, even with the dashboard closed. Only transcript text and group names are sent, never audio. The other dataset stays off until you turn it on separately."
    }
}

struct AnalysisStatusBox: View {
    let model: AppModel
    let dataset: Dataset
    let coverage: AnalysisCoverage
    let enable: () -> Void

    var body: some View {
        let state = model.analysis.state(for: dataset)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Automatic grouping").font(.headline)
                    Text(state.label)
                        .foregroundStyle(state.isPaused ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    switch state {
                    case .off:
                        Button(dataset == .sample ? "Enable sample analysis…" : "Enable real-history analysis…", action: enable)
                            .buttonStyle(.borderedProminent)
                    case .paused:
                        Button("Retry") { model.analysis.retry(dataset) }
                    case .running, .waiting:
                        ProgressView().controlSize(.small)
                    default:
                        EmptyView()
                    }
                }
                Text(coverageLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if state == .needsKey {
                    Text("Add an Anthropic API key in Settings to resume.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var coverageLine: String {
        var parts = ["Analyzed \(coverage.analyzed) of \(coverage.total) dictations", "\(coverage.pending) pending"]
        if coverage.blocked > 0 { parts.append("\(coverage.blocked) too long to analyze") }
        if let last = coverage.lastAnalyzedAt {
            parts.append("last analyzed \(last.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("not analyzed yet")
        }
        return parts.joined(separator: " · ")
    }
}

struct RepeatedList: View {
    let title: String
    let caption: String
    let items: [RepeatedText]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
                if items.isEmpty {
                    Text("Nothing repeated yet.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.text).lineLimit(2)
                            Spacer()
                            Text("\(item.count)×")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(6)
        }
    }
}

struct GroupCard: View {
    let group: GroupSummary
    /// Only the groups shown on the overview have a color.
    let color: Color?
    let isHighlighted: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.evidence) { evidence in
                        EvidenceRow(evidence: evidence)
                    }
                }
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        if let color {
                            Circle().fill(color).frame(width: 10, height: 10)
                        }
                        Text(group.label).font(.headline)
                        Text("\(group.sourceCount) \(group.sourceCount == 1 ? "dictation" : "dictations")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(group.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color ?? .accentColor, lineWidth: 2)
                .opacity(isHighlighted ? 1 : 0)
        }
    }
}

struct EvidenceRow: View {
    let evidence: GroupEvidence
    @State private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(evidence.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showOriginal ? "Hide dictation" : "Show dictation") { showOriginal.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(evidence.excerpts, id: \.self) { excerpt in
                Text("“\(excerpt)”")
                    .italic()
                    .textSelection(.enabled)
            }
            if showOriginal {
                Text(evidence.transcriptText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
