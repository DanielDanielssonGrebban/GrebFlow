import AppKit

@main
@MainActor
enum GrebFlowClaudeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusController: StatusItemController?
    private var dashboard: DashboardWindowController?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use the app as host; keep it inert so tests never touch
        // the microphone, event taps, or the menu bar.
        guard !isRunningTests else { return }

        SingleInstance.takeOver()
        NSApp.mainMenu = Self.makeMainMenu()
        let model: AppModel
        do {
            model = try AppModel.live()
        } catch {
            let alert = NSAlert()
            alert.messageText = "GrebFlowClaude couldn't open its local history"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let dashboard = DashboardWindowController(model: model)
        self.model = model
        self.dashboard = dashboard
        statusController = StatusItemController(model: model) { [weak dashboard] tab in
            dashboard?.show(tab: tab)
        }
        model.start()
        // `open GrebFlowClaude.app --args --dashboard` shows the window at
        // launch, handy when the menu bar icon is hidden behind the notch.
        if CommandLine.arguments.contains("--dashboard") {
            dashboard.show(tab: .settings)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else { return }
        Task { await model.setup.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard?.show(tab: nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    /// Accessory apps have no menu bar of their own, but the dashboard's text
    /// fields still need the standard Edit shortcuts (paste an API key, etc.).
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit GrebFlowClaude", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}
