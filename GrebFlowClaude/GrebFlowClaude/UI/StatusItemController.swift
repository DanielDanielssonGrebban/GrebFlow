import AppKit
import Observation

enum StatusIconState: Equatable {
    case idle
    case recording
    case processing
    case needsSetup
}

/// Menu bar icons. They are template images, so states differ by shape and
/// movement, not only color: a microphone when idle, moving level bars while
/// recording, cycling dots while processing, and a crossed-out microphone
/// when setup is needed. Every state carries a "C" badge so this icon can be
/// told apart from GrebFlowSol's and GrebFlowArgon's.
enum StatusIcon {
    static let size = NSSize(width: 27, height: 18)
    static let badge = "C"
    private static let glyphRect = NSRect(x: 0, y: 0, width: 18, height: 18)

    static func image(for state: StatusIconState, levels: [Float], frame: Int) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            switch state {
            case .idle: drawSymbol("mic")
            case .needsSetup: drawSymbol("mic.slash")
            case .recording: drawLevelBars(levels)
            case .processing: drawDots(frame: frame)
            }
            drawBadge()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch state {
        case .idle: "GrebFlowClaude ready"
        case .needsSetup: "GrebFlowClaude needs setup"
        case .recording: "GrebFlowClaude recording"
        case .processing: "GrebFlowClaude processing"
        }
        return image
    }

    private static func drawSymbol(_ name: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let symbolSize = symbol.size
        let origin = NSPoint(x: glyphRect.midX - symbolSize.width / 2, y: glyphRect.midY - symbolSize.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
    }

    private static func drawBadge() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .heavy),
            .foregroundColor: NSColor.black,
        ]
        let text = NSAttributedString(string: badge, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: size.width - textSize.width - 0.5, y: (size.height - textSize.height) / 2))
    }

    private static func drawLevelBars(_ levels: [Float]) {
        let count = 5
        let barWidth: CGFloat = 2.2
        let gap: CGFloat = 1.4
        let total = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = glyphRect.midX - total / 2
        // Center bars respond more strongly, which reads as a waveform.
        let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
        for index in 0..<count {
            let level = CGFloat(index < levels.count ? levels[index] : 0)
            let height = max(3, (glyphRect.height - 3) * min(1, 0.15 + level * weights[index]))
            let bar = NSRect(x: x, y: glyphRect.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    private static func drawDots(frame: Int) {
        let radiusSmall: CGFloat = 1.6
        let radiusLarge: CGFloat = 2.6
        let spacing: CGFloat = 5.2
        let active = frame % 3
        for index in 0..<3 {
            let radius = index == active ? radiusLarge : radiusSmall
            let center = NSPoint(x: glyphRect.midX + CGFloat(index - 1) * spacing, y: glyphRect.midY)
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }
}

/// Retained for the app's lifetime. Never opens a window during dictation.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let openDashboard: (DashboardTab?) -> Void
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var levelHistory: [Float] = Array(repeating: 0, count: 5)
    private var currentState: StatusIconState = .idle

    init(model: AppModel, openDashboard: @escaping (DashboardTab?) -> Void) {
        self.model = model
        self.openDashboard = openDashboard
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "GrebFlowClaude"
        observe()
    }

    private var state: StatusIconState {
        switch model.coordinator.phase {
        case .starting, .recording: .recording
        case .finalizing: .processing
        case .idle: model.setup.isReady ? .idle : .needsSetup
        }
    }

    private func observe() {
        withObservationTracking {
            _ = model.coordinator.phase
            _ = model.coordinator.level
            _ = model.setup.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        let state = state
        if state == .recording {
            levelHistory.removeFirst()
            levelHistory.append(model.coordinator.level)
        } else {
            levelHistory = Array(repeating: 0, count: levelHistory.count)
        }
        if state == .processing {
            startAnimation()
        } else {
            stopAnimation()
        }
        currentState = state
        render()
    }

    private func render() {
        // Spread recent levels across the bars so the icon moves even when
        // loudness is steady.
        let levels = [levelHistory[1], levelHistory[3], levelHistory[4], levelHistory[2], levelHistory[0]]
        statusItem.button?.image = StatusIcon.image(for: currentState, levels: levels, frame: animationFrame)
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.animationFrame += 1
                self.render()
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.setup.refreshPermissions()
        menu.removeAllItems()

        let title = disabled("GrebFlowClaude")
        title.attributedTitle = NSAttributedString(string: "GrebFlowClaude", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(title)
        menu.addItem(disabled(statusLine))
        if let problem = model.setup.snapshot.problem, model.coordinator.phase == .idle {
            menu.addItem(disabled("Setup: \(problem)"))
        }
        if let notice = model.coordinator.notice {
            menu.addItem(disabled(notice))
        }
        if let storageError = model.storageError {
            menu.addItem(disabled(storageError))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Hold \(model.preferences.shortcut.label) to dictate · Esc cancels"))
        menu.addItem(.separator())

        menu.addItem(action("Open Dashboard", #selector(openDashboardAction), key: "d"))
        let copy = action("Copy Latest Transcript", #selector(copyLatestAction), key: "c")
        copy.isEnabled = model.coordinator.latestTranscript != nil
        menu.addItem(copy)
        menu.addItem(action("Settings…", #selector(openSettingsAction), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit GrebFlowClaude", #selector(quitAction), key: "q"))
    }

    private var statusLine: String {
        switch model.coordinator.phase {
        case .starting: "Starting…"
        case .recording: "Recording…"
        case .finalizing: "Processing…"
        case .idle: model.setup.isReady ? "Ready" : "Setup needed"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openDashboardAction() { openDashboard(nil) }
    @objc private func openSettingsAction() { openDashboard(.settings) }
    @objc private func copyLatestAction() { model.copyLatestTranscript() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
