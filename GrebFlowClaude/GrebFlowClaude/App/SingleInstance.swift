import AppKit
import os

/// Makes sure only one GrebFlowClaude runs. Two copies would both react to
/// the shortcut and paste every dictation twice, and they'd share the same
/// history stores. The newest launch wins, so a fresh build from another
/// worktree replaces whatever was running.
@MainActor
enum SingleInstance {
    private static let logger = Logger(subsystem: AppModel.bundleID, category: "app")

    /// Quits older copies and waits for them to exit before this one opens
    /// the stores. Asks nicely first so they can restore muted output and
    /// remove their event tap, then forces it.
    static func takeOver() {
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppModel.bundleID)
            .filter { $0.processIdentifier != current }
        guard !others.isEmpty else { return }
        logger.notice("Quitting \(others.count) older copy of the app")

        others.forEach { $0.terminate() }
        if !waitForExit(others, seconds: 2) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            if !waitForExit(others, seconds: 2) {
                logger.error("An older copy of the app didn't quit")
            }
        }
    }

    private static func waitForExit(_ apps: [NSRunningApplication], seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        // isTerminated is updated on the main run loop, so keep it turning.
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return apps.allSatisfy(\.isTerminated)
    }
}
