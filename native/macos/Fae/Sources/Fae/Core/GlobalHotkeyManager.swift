import AppKit
import Carbon

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
    static let holdToTalkKeyCode: UInt16 = 61

    private var pttMonitor: Any?
    private var pttOnPress: (() -> Void)?
    private var pttOnRelease: (() -> Void)?
    private var pttKeyIsDown: Bool = false

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

    /// Start monitoring the hold-to-talk key (default: Right Option, keyCode 61).
    ///
    /// `onPress` fires on key-down; `onRelease` fires on key-up.
    /// Safe to call multiple times — replaces the previous callbacks and monitor.
    /// Requires Accessibility permission (same as the summon hotkey).
    func startHoldToTalk(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        // Clean up any existing PTT monitor
        stopHoldToTalk()

        self.pttOnPress = onPress
        self.pttOnRelease = onRelease
        self.pttKeyIsDown = false

        // Only start if Accessibility is trusted (don't re-prompt here)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            NSLog("GlobalHotkeyManager: Accessibility not trusted — PTT monitor not started")
            return
        }

        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard event.keyCode == Self.holdToTalkKeyCode else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let optionPressed = event.modifierFlags.contains(.option)
                if optionPressed, !self.pttKeyIsDown {
                    self.pttKeyIsDown = true
                    self.pttOnPress?()
                } else if !optionPressed, self.pttKeyIsDown {
                    self.pttKeyIsDown = false
                    self.pttOnRelease?()
                }
            }
        }
        NSLog("GlobalHotkeyManager: hold-to-talk monitor started (Right Option)")
    }

    /// Stop hold-to-talk monitoring only (leaves summon hotkey intact).
    ///
    /// Safe to call even if hold-to-talk was never started.
    func stopHoldToTalk() {
        if let m = pttMonitor {
            NSEvent.removeMonitor(m)
            pttMonitor = nil
        }
        pttKeyIsDown = false
        pttOnPress = nil
        pttOnRelease = nil
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
    }
}
