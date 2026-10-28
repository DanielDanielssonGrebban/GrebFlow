import SwiftUI

struct HistoryView: View {
    let model: AppModel

    var body: some View {
        let transcripts = model.insights.transcripts
        if transcripts.isEmpty {
            ContentUnavailableView(
                "No transcripts yet",
                systemImage: "mic",
                description: Text(model.selectedDataset == .real
                    ? "Hold \(model.preferences.shortcut.label) and speak. Released text shows up here."
                    : "Use Reset sample data in Settings to recreate the demo history.")
            )
        } else {
            Table(transcripts) {
                TableColumn("Time") { transcript in
                    Text(transcript.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 140, max: 170)
                TableColumn("Transcript") { transcript in
                    Text(transcript.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(transcript.text)
                }
                TableColumn("Duration") { transcript in
                    Text(Formatters.shortDuration(transcript.durationSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70, max: 80)
                TableColumn("Paste") { transcript in
                    Text(transcript.outcome == .pasteAttempted ? "Sent" : "Copy only")
                        .foregroundStyle(transcript.outcome == .pasteAttempted ? Color.secondary : Color.orange)
                }
                .width(min: 60, ideal: 70, max: 80)
                TableColumn("") { transcript in
                    Button("Copy") { model.copy(transcript.text) }
                }
                .width(56)
            }
        }
    }
}
