import AppKit
import SwiftUI

/// Manages a single About Fae window, reusing it when already visible.
@MainActor
final class AboutWindowController {

    private var window: NSWindow?

    /// Dependencies — set by FaeAppDelegate before first use.
    var conversation: ConversationController?
    var sparkleUpdater: SparkleUpdaterController?
    var faeCore: FaeCore?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        guard let conversation, let sparkleUpdater, let faeCore else {
            NSLog("AboutWindowController: dependencies not wired — cannot show")
            return
        }

        let view = AboutWindowView(
            conversation: conversation,
            sparkleUpdater: sparkleUpdater,
            faeCore: faeCore
        )

        let hostingController = NSHostingController(rootView: view)

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About Fae"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        window = panel
    }
}
