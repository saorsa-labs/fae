import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var conversationBridge: ConversationBridgeController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @State private var viewLoaded = false

    private static var menuHandlersKey: UInt8 = 0

    var body: some View {
        ZStack {
            if !onboarding.isStateRestored || !onboarding.isComplete {
                // Show a blank black screen while onboarding state is being
                // restored or while the separate onboarding window is active.
                // The main window is hidden during onboarding anyway.
                Color.black
            } else {
                conversationView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Fae orb, currently \(orbState.mode.label) and feeling \(orbState.feeling.label)")
        .background(
            Group {
                Color.black
                NSWindowAccessor { window in
                    windowState.window = window
                }
            }
        )
        .animation(.easeInOut(duration: 0.4), value: onboarding.isComplete)
        .animation(.easeInOut(duration: 0.3), value: onboarding.isStateRestored)
    }

    // MARK: - Context Menu

    private func showOrbContextMenu() {
        guard let window = windowState.window,
              let contentView = window.contentView else { return }

        let menu = NSMenu()

        // Settings — SwiftUI Settings scene uses the AppKit responder chain
        // selector "showSettingsWindow:" which is the standard macOS action.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: Selector(("showSettingsWindow:")),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Reset Conversation
        let resetHandler = MenuActionHandler { [conversation, conversationBridge] in
            conversation.clearMessages()
            conversationBridge.webView?.evaluateJavaScript(
                "window.clearMessages && window.clearMessages();",
                completionHandler: nil
            )
        }
        let resetItem = NSMenuItem(
            title: "Reset Conversation",
            action: #selector(MenuActionHandler.invoke),
            keyEquivalent: ""
        )
        resetItem.target = resetHandler
        menu.addItem(resetItem)

        // Hide Fae
        let hideHandler = MenuActionHandler { [windowState] in
            windowState.hideWindow()
        }
        let hideItem = NSMenuItem(
            title: "Hide Fae",
            action: #selector(MenuActionHandler.invoke),
            keyEquivalent: ""
        )
        hideItem.target = hideHandler
        menu.addItem(hideItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Fae",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        // Retain handlers for the lifetime of the menu via associated object
        objc_setAssociatedObject(
            menu, &ContentView.menuHandlersKey,
            [resetHandler, hideHandler] as NSArray,
            .OBJC_ASSOCIATION_RETAIN
        )

        // Show at mouse location
        let mouseLocation = window.mouseLocationOutsideOfEventStream
        menu.popUp(positioning: nil, at: mouseLocation, in: contentView)
    }

    // MARK: - Conversation View

    private var conversationView: some View {
        ZStack {
            ConversationWebView(
                mode: orbState.mode,
                palette: orbState.palette,
                feeling: orbState.feeling,
                isListening: conversation.isListening,
                windowMode: windowState.mode.rawValue,
                onLoad: { withAnimation(.easeIn(duration: 0.4)) { viewLoaded = true } },
                onWebViewReady: { webView in
                    conversationBridge.webView = webView
                    pipelineAux.webView = webView
                },
                onUserMessage: { text in
                    conversation.handleUserSent(text)
                    windowState.noteActivity()
                },
                onToggleListening: {
                    conversation.toggleListening()
                    windowState.noteActivity()
                },
                onLinkDetected: { url in conversation.handleLinkDetected(url) },
                onOpenConversationWindow: { auxiliaryWindows.toggleConversation() },
                onOpenCanvasWindow: { auxiliaryWindows.toggleCanvas() },
                onUserInteraction: { windowState.noteActivity() },
                onOrbClicked: {
                    if windowState.mode == .collapsed {
                        windowState.transitionToCompact()
                    }
                },
                onOrbContextMenu: {
                    showOrbContextMenu()
                }
            )
            .opacity(viewLoaded ? 1 : 0)
            .onChange(of: auxiliaryWindows.isConversationVisible) { _, visible in
                conversationBridge.webView?.evaluateJavaScript(
                    "window.setPanelVisibility && window.setPanelVisibility('conversation', \(visible));",
                    completionHandler: nil
                )
            }
            .onChange(of: auxiliaryWindows.isCanvasVisible) { _, visible in
                conversationBridge.webView?.evaluateJavaScript(
                    "window.setPanelVisibility && window.setPanelVisibility('canvas', \(visible));",
                    completionHandler: nil
                )
            }

            if !viewLoaded {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 200, height: 200)
                    .scaleEffect(0.95)
                    .opacity(0.5)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                        value: viewLoaded
                    )
                    .transition(.opacity)
            }
        }
    }
}

/// Lightweight Objective-C target for NSMenuItem action callbacks.
private final class MenuActionHandler: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func invoke() {
        closure()
    }
}
