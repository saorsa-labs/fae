import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var orbAnimation: OrbAnimationState
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var conversationBridge: ConversationBridgeController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var subtitles: SubtitleStateController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @State private var viewLoaded = false

    private static var menuHandlersKey: UInt8 = 0

    var body: some View {
        ZStack {
            if !onboarding.isStateRestored || !onboarding.isComplete {
                // Show a blank dark surface while onboarding state is being
                // restored or while the separate onboarding window is active.
                // The main window is hidden during onboarding anyway.
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
            } else {
                nativeConversationView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Fae orb, currently \(orbState.mode.label) and feeling \(orbState.feeling.label)")
        .background(
            NSWindowAccessor { window in
                // Setting the window triggers WindowStateController's didSet
                // which enforces compact size, installs frosted glass, and
                // sets up the title-bar hover tracker — all in the correct order.
                windowState.window = window
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
        let resetHandler = MenuActionHandler { [conversation, subtitles] in
            conversation.clearMessages()
            subtitles.clearAll()
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

    // MARK: - Native Conversation View

    /// Fully native layered UI:
    /// - Layer 0: Metal orb animation (GPU-rendered fog-cloud orb)
    /// - Layer 1: Progress bar overlay
    /// - Layer 2: Subtitle bubbles (assistant, user, tool)
    /// - Layer 3: Input bar (mic toggle, text field, send button, action pills)
    private var nativeConversationView: some View {
        ZStack {
            // Layer 0: Metal orb animation (replaces WKWebView)
            NativeOrbView(
                orbAnimation: orbAnimation,
                audioRMS: pipelineAux.audioRMS,
                windowMode: windowState.mode.rawValue,
                onLoad: { withAnimation(.easeIn(duration: 0.4)) { viewLoaded = true } },
                onOrbClicked: {
                    if windowState.mode == .collapsed {
                        windowState.transitionToCompact()
                    }
                },
                onOrbContextMenu: {
                    showOrbContextMenu()
                }
            )
            // Inset the orb below the title bar so the frosted-glass
            // background shows through the transparent title bar region.
            .padding(.top, 28)
            .opacity(viewLoaded ? 1 : 0)

            // Only show overlays in compact mode (not collapsed 80×80 orb)
            if windowState.mode == .compact {
                // Layer 1: Progress bar (always visible for download/load feedback)
                ProgressOverlayView()

                // Layer 2: Subtitle overlay (above input bar)
                SubtitleOverlayView()
                    .padding(.bottom, pipelineAux.isPipelineReady ? 80 : 0)

                // Layer 3: Input bar — hidden until models are loaded so
                // users don't try to chat before the pipeline is ready.
                if pipelineAux.isPipelineReady {
                    InputBarView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Loading placeholder
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
