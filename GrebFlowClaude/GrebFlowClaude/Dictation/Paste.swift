import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import os

enum PasteNormalizer {
    /// Turns recognized text into safe single-line text. Line breaks,
    /// Unicode line and paragraph separators, tabs, and other control
    /// characters become spaces, so a terminal never sees an embedded Return.
    /// Punctuation and non-ASCII text are left alone. Leading and trailing
    /// whitespace is trimmed.
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isBreaking(scalar) || scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// What actually gets pasted: the normalized text plus exactly one
    /// trailing space, so the next dictation continues the sentence. Nil for
    /// an empty transcript, which never pastes a lone space.
    static func insertionText(for text: String) -> String? {
        let normalized = normalize(text)
        return normalized.isEmpty ? nil : normalized + " "
    }

    private static func isBreaking(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}

/// Builds the synthetic Command-V sequence. Kept separate from posting so the
/// tests inspect the same events the app sends.
struct PasteEventFactory {
    static let commandKey: CGKeyCode = 55
    static let vKey: CGKeyCode = 9

    static let localFilter: CGEventFilterMask = [
        .permitLocalKeyboardEvents,
        .permitLocalMouseEvents,
        .permitSystemDefinedEvents,
    ]

    /// One private source per paste, so the sequence doesn't inherit
    /// modifier state from the user's physical keyboard.
    func makeSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(Self.localFilter, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(Self.localFilter, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }

    /// Left Command down, V down, V up, Left Command up. Ends with empty
    /// flags. Never contains Return, Option, Shift, or Control.
    func makePasteEvents(source: CGEventSource) -> [CGEvent]? {
        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: Self.commandKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKey, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: Self.commandKey, keyDown: false)
        else { return nil }

        commandDown.type = .flagsChanged
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.type = .flagsChanged
        commandUp.flags = []
        return [commandDown, vDown, vUp, commandUp]
    }
}

enum PasteOutcome: String, Codable, Sendable {
    case pasteAttempted
    case copyOnly
}

enum PasteSkipReason: String, Sendable, Equatable {
    case destinationChanged
    case focusedFieldChanged
    case modifiersStillHeld
    case clipboardChanged
    case secureInput
    case noPostAccess
    case eventCreationFailed
    case watchdog

    var message: String {
        switch self {
        case .destinationChanged: "The active app changed before paste. Use Copy latest transcript."
        case .focusedFieldChanged: "The focused field changed before paste. Use Copy latest transcript."
        case .modifiersStillHeld: "Modifier keys were still held, so GrebFlowClaude didn't paste. Use Copy latest transcript."
        case .clipboardChanged: "Another app changed the clipboard just before paste, so GrebFlowClaude didn't paste. Use Copy latest transcript."
        case .secureInput: "A secure text field is active, so GrebFlowClaude didn't paste."
        case .noPostAccess: "GrebFlowClaude can't send the paste shortcut. Check Accessibility in Settings."
        case .eventCreationFailed: "The paste shortcut couldn't be created."
        case .watchdog: "Recording hit the five-minute limit. The text was kept for manual copy."
        }
    }
}

enum PasteResult: Equatable, Sendable {
    case pasteAttempted
    case copyOnly(PasteSkipReason)

    var outcome: PasteOutcome {
        switch self {
        case .pasteAttempted: .pasteAttempted
        case .copyOnly: .copyOnly
        }
    }
}

/// Where the user was when they pressed the shortcut. The focused element is
/// only compared for identity, never read.
struct PasteDestination {
    var processID: pid_t?
    var bundleID: String?
    var focusedElement: AXUIElement?
}

@MainActor
protocol TextInserting: AnyObject {
    var isSecureInputActive: Bool { get }
    func captureDestination() -> PasteDestination
    func insert(_ text: String, into destination: PasteDestination, shortcut: DictationShortcut) async -> PasteResult
}

/// The system calls the paste guard depends on, behind one seam so tests
/// can drive the guard without posting into another app.
@MainActor
protocol PasteEnvironment: AnyObject {
    var isSecureInputActive: Bool { get }
    var canPostEvents: Bool { get }
    /// Hardware modifier state, not the combined session state.
    func physicalModifierFlags() -> CGEventFlags
    func frontmostApplication() -> (processID: pid_t, bundleID: String?)?
    func focusedElement() -> AXUIElement?
    /// Writes the text and returns the pasteboard change count right after.
    func writeClipboard(_ text: String) -> Int
    func clipboardChangeCount() -> Int
    func post(_ events: [CGEvent])
}

/// Tracks whether the clipboard still holds what GrebFlowClaude last put
/// there, so Delete all history never clears something another app copied.
@MainActor
final class ClipboardOwnership {
    private var ownedChangeCount: Int?

    @discardableResult
    func write(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownedChangeCount = pasteboard.changeCount
        return pasteboard.changeCount
    }

    func clearIfOwned() {
        let pasteboard = NSPasteboard.general
        if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
            pasteboard.clearContents()
        }
        ownedChangeCount = nil
    }
}

@MainActor
final class SystemPasteEnvironment: PasteEnvironment {
    private let clipboard: ClipboardOwnership

    init(clipboard: ClipboardOwnership) {
        self.clipboard = clipboard
    }

    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
    var canPostEvents: Bool { CGPreflightPostEventAccess() }

    func physicalModifierFlags() -> CGEventFlags { CGEventSource.flagsState(.hidSystemState) }

    func frontmostApplication() -> (processID: pid_t, bundleID: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.processIdentifier, app.bundleIdentifier)
    }

    func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func writeClipboard(_ text: String) -> Int { clipboard.write(text) }

    func clipboardChangeCount() -> Int { NSPasteboard.general.changeCount }

    func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cghidEventTap) }
    }
}

/// Decides whether a paste is safe and, if so, sends it. Three apps share
/// one clipboard and one keyboard, so it waits until every physical
/// modifier is up and checks that nobody wrote to the clipboard in between.
@MainActor
final class PasteInserter: TextInserting {
    static let blockingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]

    private let environment: PasteEnvironment
    private let factory = PasteEventFactory()
    private let releaseTimeout: Duration
    private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "paste")

    init(environment: PasteEnvironment, releaseTimeout: Duration = .seconds(2)) {
        self.environment = environment
        self.releaseTimeout = releaseTimeout
    }

    var isSecureInputActive: Bool { environment.isSecureInputActive }

    func captureDestination() -> PasteDestination {
        let app = environment.frontmostApplication()
        return PasteDestination(processID: app?.processID, bundleID: app?.bundleID, focusedElement: environment.focusedElement())
    }

    func insert(_ text: String, into destination: PasteDestination, shortcut: DictationShortcut) async -> PasteResult {
        guard await waitForModifierRelease(shortcut: shortcut) else { return skip(.modifiersStillHeld) }
        guard environment.frontmostApplication()?.processID == destination.processID else { return skip(.destinationChanged) }
        if let captured = destination.focusedElement, let current = environment.focusedElement(), !CFEqual(captured, current) {
            return skip(.focusedFieldChanged)
        }
        guard !environment.isSecureInputActive else { return skip(.secureInput) }
        guard environment.canPostEvents else { return skip(.noPostAccess) }
        guard let source = factory.makeSource(), let events = factory.makePasteEvents(source: source) else {
            return skip(.eventCreationFailed)
        }

        let written = environment.writeClipboard(text)
        guard environment.clipboardChangeCount() == written else { return skip(.clipboardChanged) }
        environment.post(events)
        return .pasteAttempted
    }

    private func skip(_ reason: PasteSkipReason) -> PasteResult {
        logger.notice("Paste skipped: \(reason.rawValue, privacy: .public)")
        return .copyOnly(reason)
    }

    private func waitForModifierRelease(shortcut: DictationShortcut) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + releaseTimeout
        while true {
            let flags = environment.physicalModifierFlags()
            let shortcutHeld = flags.rawValue & shortcut.deviceFlag != 0
            if !shortcutHeld && flags.intersection(Self.blockingModifiers).isEmpty { return true }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
