import AppKit
import SwiftUI

@MainActor
final class CoworkWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var controller: CoworkWorkspaceController?

    var currentWindow: NSWindow? { window }

    var faeCore: FaeCore?
    var conversation: ConversationController?
    var runtimeDescriptor: FaeLocalRuntimeDescriptor?
    var orbAnimation: OrbAnimationState?
    var pipelineAux: PipelineAuxBridgeController?

    func show() {
        if let window {
            controller?.scheduleRefresh(after: 0.05)
            announceVisibility(true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let faeCore, let conversation else {
            NSLog("CoworkWindowController: dependencies not wired")
            return
        }

        let controller = CoworkWorkspaceController(
            faeCore: faeCore,
            conversation: conversation,
            runtimeDescriptor: runtimeDescriptor
        )
        let rootView = CoworkWorkspaceView(
            controller: controller,
            faeCore: faeCore,
            conversation: conversation
        )

        let hostingController = NSHostingController(rootView: rootView)
        // Allow the window to freely resize without SwiftUI constraining it to ideal size.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = .minSize
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Work with Fae"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1120, height: 760)
        window.center()
        window.delegate = self
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.controller = controller
        self.window = window
        announceVisibility(true)
    }

    func windowWillClose(_ notification: Notification) {
        announceVisibility(false)
        window = nil
        controller = nil
    }

    private func announceVisibility(_ visible: Bool) {
        NotificationCenter.default.post(
            name: .faeCoworkWindowVisibilityChanged,
            object: nil,
            userInfo: ["visible": visible]
        )
    }
}
