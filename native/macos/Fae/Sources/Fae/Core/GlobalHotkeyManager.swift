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
    }
}
