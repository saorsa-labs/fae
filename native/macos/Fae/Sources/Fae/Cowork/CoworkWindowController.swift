import AppKit
import SwiftUI

@MainActor
final class CoworkWindowController {
    private var window: NSWindow?
    private var controller: CoworkWorkspaceController?

    var faeCore: FaeCore?
    var conversation: ConversationController?

    func show() {
        if let window {
            controller?.scheduleRefresh(after: 0.05)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let faeCore, let conversation else {
            NSLog("CoworkWindowController: dependencies not wired")
            return
        }

        let controller = CoworkWorkspaceController(faeCore: faeCore, conversation: conversation)
        let rootView = CoworkWorkspaceView(
            controller: controller,
            faeCore: faeCore,
            conversation: conversation
        )

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Fae Cowork"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1120, height: 760)
        window.center()
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.controller = controller
        self.window = window
    }
}
