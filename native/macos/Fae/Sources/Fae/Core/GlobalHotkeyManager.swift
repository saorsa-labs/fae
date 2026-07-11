import AppKit
import Carbon

enum RightOptionChordAction: Equatable {
    case schedulePTT
    case cancelScheduledPTT
    case pressPTT
    case releasePTT
    case toggleVisibility
}

struct RightOptionChordState {
    private let pttEnabled: Bool

    init(pttEnabled: Bool = true) {
        self.pttEnabled = pttEnabled
    }
    private(set) var rightOptionDown = false
    private(set) var shiftDown = false
    private(set) var pendingPTT = false
    private(set) var pttActive = false
    private(set) var visibilityChordLatched = false

    mutating func rightOptionChanged(isDown: Bool, shiftIsDown: Bool) -> [RightOptionChordAction] {
        shiftDown = shiftIsDown
        if isDown {
            guard !rightOptionDown else { return [] }
            rightOptionDown = true
            if shiftDown {
                visibilityChordLatched = true
                return [.toggleVisibility]
            }
            guard pttEnabled else { return [] }
            pendingPTT = true
            return [.schedulePTT]
        }

        guard rightOptionDown else { return [] }
        rightOptionDown = false
        if visibilityChordLatched {
            visibilityChordLatched = false
            pendingPTT = false
            return []
        }
        if pendingPTT {
            pendingPTT = false
            return [.cancelScheduledPTT, .pressPTT, .releasePTT]
        }
        if pttActive {
            pttActive = false
            return [.releasePTT]
        }
        return []
    }

    mutating func shiftChanged(isDown: Bool) -> [RightOptionChordAction] {
        shiftDown = isDown
        guard isDown, rightOptionDown, !pttActive, !visibilityChordLatched else {
            return []
        }
        visibilityChordLatched = true
        if pendingPTT {
            pendingPTT = false
            return [.cancelScheduledPTT, .toggleVisibility]
        }
        return [.toggleVisibility]
    }

    mutating func pttDelayElapsed() -> [RightOptionChordAction] {
        guard pendingPTT, rightOptionDown, !shiftDown, !visibilityChordLatched else { return [] }
        pendingPTT = false
        pttActive = true
        return [.pressPTT]
    }

    mutating func reset() {
        self = RightOptionChordState(pttEnabled: pttEnabled)
    }
}

/// Manages a global hotkey that summons Fae from anywhere on the system.
///
/// Uses `NSEvent.addGlobalMonitorForEvents` to listen for keyboard events
/// while Fae is not the frontmost app. Requires Accessibility permission
/// (the macOS system dialog is shown automatically if not yet granted).
///
/// Default hotkey: **Ctrl+Shift+A** (configurable in Phase 2).
@MainActor
final class GlobalHotkeyManager {

    private var monitor: Any?
    private var handler: (() -> Void)?

    // MARK: - Push-to-Talk (Hold-to-Talk)

    /// Key code for the Right Option key.
    nonisolated static let holdToTalkKeyCode: UInt16 = 61

    private var pttMonitor: Any?
    private var pttKeyUpMonitor: Any?
    private var pttLocalMonitor: Any?
    private var pttLocalKeyUpMonitor: Any?
    private var visibilityChordMonitor: Any?
    private var visibilityChordLocalMonitor: Any?
    private var pttOnPress: (() -> Void)?
    private var pttOnRelease: (() -> Void)?
    private var pttKeyIsDown: Bool = false
    private var pttOnToggleVisibility: (() -> Void)?
    private var rightOptionChordState = RightOptionChordState()
    private var pttDisambiguationTask: Task<Void, Never>?
    private static let pttChordDisambiguationNanoseconds: UInt64 = 150_000_000

    /// Modifier flag for a modifier key code, or nil for regular keys (which
    /// use keyDown/keyUp monitors instead of flagsChanged).
    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 58, 61: return .option
        case 54, 55: return .command
        case 59, 62: return .control
        case 56, 60: return .shift
        case 63: return .function
        default: return nil
        }
    }

    /// Start monitoring for the global hotkey.
    ///
    /// If Accessibility is not yet trusted, macOS shows the system dialog
    /// and this method returns without starting the monitor -- it will work
    /// on next launch after the user grants permission.
    func start(handler: @escaping () -> Void) {
        self.handler = handler

        // Check/request Accessibility permission.
        // The prompt option shows the system dialog automatically.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            NSLog("GlobalHotkeyManager: Accessibility not trusted — monitor not started (will work after grant)")
            return
        }

        startMonitor()
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Start monitoring the hold-to-talk key (default: Right Option, keyCode 61;
    /// configurable via `voice.pttHotkeyKeyCode`).
    ///
    /// `onPress` fires on key-down; `onRelease` fires on key-up. Modifier keys
    /// arrive as `.flagsChanged`; regular keys (e.g. F5) as `.keyDown`/`.keyUp`.
    /// Safe to call multiple times — replaces the previous callbacks and monitor.
    /// Requires Accessibility permission (same as the summon hotkey).
    func startHoldToTalk(
        keyCode: UInt16 = GlobalHotkeyManager.holdToTalkKeyCode,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onToggleVisibility: @escaping () -> Void = {}
    ) {
        // Clean up any existing PTT monitor
        stopHoldToTalk()

        self.pttOnPress = onPress
        self.pttOnRelease = onRelease
        self.pttKeyIsDown = false
        self.pttOnToggleVisibility = onToggleVisibility
        self.rightOptionChordState = RightOptionChordState(pttEnabled: keyCode == Self.holdToTalkKeyCode)

        // Only start if Accessibility is trusted (don't re-prompt here)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            NSLog("GlobalHotkeyManager: Accessibility not trusted — PTT monitor not started")
            return
        }

        // Global monitors only see events routed to OTHER apps — when Fae
        // itself is frontmost (settings open, just launched) the key would
        // be invisible. Register a local monitor alongside so the hold works
        // everywhere.
        if keyCode == Self.holdToTalkKeyCode {
            let handleFlags: (NSEvent) -> Void = { [weak self] event in
                guard event.keyCode == Self.holdToTalkKeyCode
                        || event.keyCode == 56
                        || event.keyCode == 60
                else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.handleRightOptionChordEvent(event)
                }
            }
            pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags)
            pttLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                handleFlags(event)
                return event
            }
        } else if let flag = Self.modifierFlag(for: keyCode) {
            let handleFlags: (NSEvent) -> Void = { [weak self] event in
                guard event.keyCode == keyCode else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let pressed = event.modifierFlags.contains(flag)
                    if pressed, !self.pttKeyIsDown {
                        self.pttKeyIsDown = true
                        NSLog("GlobalHotkeyManager: PTT press (keyCode %d)", keyCode)
                        self.pttOnPress?()
                    } else if !pressed, self.pttKeyIsDown {
                        self.pttKeyIsDown = false
                        NSLog("GlobalHotkeyManager: PTT release (keyCode %d)", keyCode)
                        self.pttOnRelease?()
                    }
                }
            }
            pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags)
            pttLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                handleFlags(event)
                return event
            }
        } else {
            let handleDown: (NSEvent) -> Void = { [weak self] event in
                guard event.keyCode == keyCode else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.pttKeyIsDown else { return }
                    self.pttKeyIsDown = true
                    NSLog("GlobalHotkeyManager: PTT press (keyCode %d)", keyCode)
                    self.pttOnPress?()
                }
            }
            let handleUp: (NSEvent) -> Void = { [weak self] event in
                guard event.keyCode == keyCode else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pttKeyIsDown else { return }
                    self.pttKeyIsDown = false
                    NSLog("GlobalHotkeyManager: PTT release (keyCode %d)", keyCode)
                    self.pttOnRelease?()
                }
            }
            pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handleDown)
            pttKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: handleUp)
            pttLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleDown(event)
                return event
            }
            pttLocalKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                handleUp(event)
                return event
            }
        }
        if keyCode != Self.holdToTalkKeyCode {
            let handleVisibilityChord: (NSEvent) -> Void = { [weak self] event in
                guard event.keyCode == Self.holdToTalkKeyCode
                        || event.keyCode == 56
                        || event.keyCode == 60
                else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.handleRightOptionChordEvent(event)
                }
            }
            visibilityChordMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .flagsChanged,
                handler: handleVisibilityChord
            )
            visibilityChordLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                handleVisibilityChord(event)
                return event
            }
        }
        NSLog("GlobalHotkeyManager: hold-to-talk monitor started (keyCode %d)", keyCode)
    }

    private func handleRightOptionChordEvent(_ event: NSEvent) {
        let shiftIsDown = event.modifierFlags.contains(.shift)
        let actions: [RightOptionChordAction]
        if event.keyCode == Self.holdToTalkKeyCode {
            actions = rightOptionChordState.rightOptionChanged(
                isDown: event.modifierFlags.contains(.option),
                shiftIsDown: shiftIsDown
            )
        } else {
            actions = rightOptionChordState.shiftChanged(isDown: shiftIsDown)
        }
        applyRightOptionChordActions(actions)
    }

    private func applyRightOptionChordActions(_ actions: [RightOptionChordAction]) {
        for action in actions {
            switch action {
            case .schedulePTT:
                pttDisambiguationTask?.cancel()
                pttDisambiguationTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: Self.pttChordDisambiguationNanoseconds)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.pttDisambiguationTask = nil
                    self.applyRightOptionChordActions(self.rightOptionChordState.pttDelayElapsed())
                }
            case .cancelScheduledPTT:
                pttDisambiguationTask?.cancel()
                pttDisambiguationTask = nil
            case .pressPTT:
                guard !pttKeyIsDown else { continue }
                pttKeyIsDown = true
                NSLog("GlobalHotkeyManager: PTT press (Right Option)")
                pttOnPress?()
            case .releasePTT:
                guard pttKeyIsDown else { continue }
                pttKeyIsDown = false
                NSLog("GlobalHotkeyManager: PTT release (Right Option)")
                pttOnRelease?()
            case .toggleVisibility:
                NSLog("GlobalHotkeyManager: toggle Fae visibility (Right Option+Shift)")
                pttOnToggleVisibility?()
            }
        }
    }

    /// Stop hold-to-talk monitoring only (leaves summon hotkey intact).
    ///
    /// Safe to call even if hold-to-talk was never started.
    func stopHoldToTalk() {
        if let m = pttMonitor {
            NSEvent.removeMonitor(m)
            pttMonitor = nil
        }
        if let m = pttKeyUpMonitor {
            NSEvent.removeMonitor(m)
            pttKeyUpMonitor = nil
        }
        if let m = pttLocalMonitor {
            NSEvent.removeMonitor(m)
            pttLocalMonitor = nil
        }
        if let m = pttLocalKeyUpMonitor {
            NSEvent.removeMonitor(m)
            pttLocalKeyUpMonitor = nil
        }
        if let m = visibilityChordMonitor {
            NSEvent.removeMonitor(m)
            visibilityChordMonitor = nil
        }
        if let m = visibilityChordLocalMonitor {
            NSEvent.removeMonitor(m)
            visibilityChordLocalMonitor = nil
        }
        pttDisambiguationTask?.cancel()
        pttDisambiguationTask = nil
        if pttKeyIsDown {
            pttOnRelease?()
        }
        pttKeyIsDown = false
        rightOptionChordState.reset()
        pttOnPress = nil
        pttOnRelease = nil
        pttOnToggleVisibility = nil
    }

    private func startMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Ctrl+Shift+A  (keyCode 0 = 'a' on US keyboard)
            let mods = event.modifierFlags.intersection([.control, .shift, .command, .option])
            guard mods == [.control, .shift], event.keyCode == 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.handler?()
            }
        }
        NSLog("GlobalHotkeyManager: global hotkey monitor started (Ctrl+Shift+A)")
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
        if let m = pttMonitor {
            NSEvent.removeMonitor(m)
        }
        if let m = pttKeyUpMonitor {
            NSEvent.removeMonitor(m)
        }
        if let m = pttLocalMonitor {
            NSEvent.removeMonitor(m)
        }
        if let m = pttLocalKeyUpMonitor {
            NSEvent.removeMonitor(m)
        }
    }
}
