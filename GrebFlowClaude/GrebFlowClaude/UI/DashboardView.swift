import AppKit
import Observation
import SwiftUI

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview
    case usage
    case history
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .usage: "Usage"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.bar"
        case .usage: "square.stack.3d.up"
        case .history: "clock"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class DashboardNavigation {
    var tab: DashboardTab = .overview
}

/// The dashboard is an ordinary window, opened explicitly. Closing it leaves
/// the menu bar app and dictation running.
@MainActor
final class DashboardWindowController {
    private let model: AppModel
    private let navigation = DashboardNavigation()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(tab: DashboardTab?) {
        if let tab { navigation.tab = tab }
        let window = window ?? makeWindow()
        self.window = window
        // A saved frame can point at a display that's no longer attached.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Accessory apps aren't always allowed to activate themselves; make
        // sure the window still comes to the front.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "GrebFlowClaude"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.contentViewController = NSHostingController(rootView: DashboardView(model: model, navigation: navigation))
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.center()
        window.setFrameAutosaveName("GrebFlowClaudeDashboard")
        return window
    }
}

struct DashboardView: View {
    let model: AppModel
    @Bindable var navigation: DashboardNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<DashboardTab?>(
                get: { navigation.tab },
                set: { if let tab = $0 { navigation.tab = tab } }
            )) {
                ForEach(DashboardTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.systemImage).tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if navigation.tab != .settings {
                    DatasetBar(model: model)
                    Divider()
                }
                Group {
                    switch navigation.tab {
                    case .overview: OverviewView(model: model)
                    case .usage: UsageView(model: model)
                    case .history: HistoryView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(navigation.tab.label)
        }
    }
}

struct DatasetBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("Dataset", selection: Binding(
                get: { model.selectedDataset },
                set: { model.selectedDataset = $0 }
            )) {
                ForEach(Dataset.allCases) { dataset in
                    Text(dataset.label).tag(dataset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            if model.selectedDataset == .sample {
                SampleBadge()
                Text("Fictional demo history. Live dictation always saves to real history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            DictationStatusPill(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct SampleBadge: View {
    var body: some View {
        Text("SAMPLE DATA")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}

struct DictationStatusPill: View {
    let model: AppModel

    var body: some View {
        let (text, color): (String, Color) = switch model.coordinator.phase {
        case .starting, .recording: ("Recording", .red)
        case .finalizing: ("Processing", .blue)
        case .idle: model.setup.isReady ? ("Ready", .green) : ("Setup needed", .orange)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

enum Formatters {
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    static func shortDuration(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }
}
