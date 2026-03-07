import AppKit
import SwiftUI

@MainActor
final class CoworkWindowController {
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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let faeCore, let conversation, let orbAnimation, let pipelineAux else {
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
            conversation: conversation,
            orbAnimation: orbAnimation,
            pipelineAux: pipelineAux
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
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.controller = controller
        self.window = window
    }
}
