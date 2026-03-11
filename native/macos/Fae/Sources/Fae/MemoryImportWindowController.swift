import AppKit
import SwiftUI

/// Manages a single Memory Import window, reusing it when already visible.
@MainActor
final class MemoryImportWindowController {

    private var window: NSWindow?

    /// Dependencies — set by FaeAppDelegate before first use.
    var auxiliaryWindows: AuxiliaryWindowManager?
    var memoryInboxServiceProvider: (() -> MemoryInboxService?)?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = MemoryImportWindowView(
            memoryInboxServiceProvider: { [weak self] in
                self?.memoryInboxServiceProvider?()
            },
            focusMainWindow: { [weak self] in
                self?.auxiliaryWindows?.focusMainWindow()
            },
            dismissAction: { [weak self] in
                self?.window?.close()
            }
        )

        let hostingController = NSHostingController(rootView: view)

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Memory Inbox"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 500)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        window = panel
    }
}
