import AppKit
import CoreGraphics
import os

enum ShortcutAction: Equatable {
    case pressed
    case released
    case escape
    case otherKeyWhileHeld
    case ignore
}

/// Turns raw key events into shortcut transitions. Uses the device-dependent
/// flag bits so the right-side key is tracked independently of the left one,
/// including when both are held.
///
/// Two other GrebFlow variants run on the same Mac with their own taps, so
/// this only reacts to physical events and never claims the shortcut key.
struct ShortcutInterpreter {
    static let escapeKeyCode: Int64 = 53
    /// kCGEventSourceStateHIDSystemState.
    static let hidSystemStateID: Int64 = 1

    /// Device-dependent bits for every modifier key, plus the generic Shift,
    /// Control, Option, Command, and Fn flags. Caps Lock is left out.
    static let modifierBits: UInt64 = 0x0000_207F | 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000 | 0x0080_0000

    var shortcut: DictationShortcut {
        didSet { isHeld = false }
    }

    private(set) var isHeld = false
    private var lastFlags: UInt64 = 0

    init(shortcut: DictationShortcut) {
        self.shortcut = shortcut
    }

    /// Used when the coordinator notices from hardware state that a release
    /// event never arrived.
    mutating func reset() {
        isHeld = false
    }

    mutating func interpret(type: CGEventType, keyCode: Int64, flags: UInt64, sourcePID: Int64, sourceStateID: Int64) -> ShortcutAction {
        // Synthetic events, including the other variants' Command-V and our
        // own, come from a process or a private source state.
        guard sourcePID == 0, sourceStateID == Self.hidSystemStateID else { return .ignore }

        switch type {
        case .flagsChanged where keyCode == shortcut.keyCode:
            lastFlags = flags
            let down = Self.isRightKeyDown(shortcut: shortcut, flags: flags)
            if down && !isHeld {
                isHeld = true
                return .pressed
            }
            if !down && isHeld {
                isHeld = false
                return .released
            }
            return .ignore
        case .flagsChanged:
            // Another modifier went down during the hold: the user is typing
            // or using a shortcut, or holding another variant's key.
            let newlyDown = flags & ~lastFlags & Self.modifierBits
            lastFlags = flags
            return isHeld && newlyDown != 0 ? .otherKeyWhileHeld : .ignore
        case .keyDown where keyCode == Self.escapeKeyCode:
            return .escape
        case .keyDown where isHeld:
            return .otherKeyWhileHeld
        default:
            return .ignore
        }
    }

    /// Some keyboards don't report device bits. In that case fall back to the
    /// generic modifier flag, as long as the left key isn't the one reporting.
    static func isRightKeyDown(shortcut: DictationShortcut, flags: UInt64) -> Bool {
        if flags & shortcut.deviceFlag != 0 { return true }
        let anyDeviceBit = flags & (shortcut.deviceFlag | shortcut.leftDeviceFlag) != 0
        return !anyDeviceBit && flags & shortcut.genericFlag != 0
    }
}

/// Installs a Quartz event tap for flagsChanged and keyDown. The callback
/// runs on the main run loop and only translates the event; the coordinator
/// does the work. Every event passes through unchanged, except Escape while
/// this app is recording.
@MainActor
final class ShortcutMonitor {
    var onAction: ((ShortcutAction) -> Void)?
    /// Asked before swallowing Escape, so Escape only reaches GrebFlowClaude while
    /// a recording is active.
    var shouldConsumeEscape: () -> Bool = { false }

    private var interpreter: ShortcutInterpreter
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "shortcut")

    init(shortcut: DictationShortcut) {
        interpreter = ShortcutInterpreter(shortcut: shortcut)
    }

    var isInstalled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    var shortcut: DictationShortcut {
        get { interpreter.shortcut }
        set { interpreter.shortcut = newValue }
    }

    var isShortcutHeld: Bool { interpreter.isHeld }

    func resetHeldState() {
        interpreter.reset()
    }

    @discardableResult
    func install() -> Bool {
        if tap != nil { return isInstalled }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: shortcutTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.notice("Event tap could not be created")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
    }

    /// Returns true if the event should be swallowed.
    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: UInt64, sourcePID: Int64, sourceStateID: Int64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.notice("Event tap was disabled by the system; re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let action = interpreter.interpret(type: type, keyCode: keyCode, flags: flags, sourcePID: sourcePID, sourceStateID: sourceStateID)
        guard action != .ignore else { return false }
        let consume = action == .escape && shouldConsumeEscape()
        onAction?(action)
        return consume
    }
}

private func shortcutTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    let sourceStateID = event.getIntegerValueField(.eventSourceStateID)
    // The tap's run loop source is on the main run loop.
    let consume = MainActor.assumeIsolated {
        monitor.handle(type: type, keyCode: keyCode, flags: flags, sourcePID: sourcePID, sourceStateID: sourceStateID)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
