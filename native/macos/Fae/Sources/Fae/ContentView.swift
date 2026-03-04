import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var orbAnimation: OrbAnimationState
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @State private var viewLoaded = false

    private static var menuHandlersKey: UInt8 = 0

    var body: some View {
        ZStack {
            if windowState.mode == .collapsed {
                collapsedView
            } else {
                compactView
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Frosted glass in compact mode, clear in collapsed so the orb floats.
        .background {
            if windowState.mode != .collapsed {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
            }
        }
        .clipShape(
            windowState.mode == .collapsed
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .preferredColorScheme(.dark)
        .accessibilityLabel("Fae orb, currently \(orbState.mode.label) and feeling \(orbState.feeling.label)")
        .background(
            NSWindowAccessor { window in
                windowState.window = window
            }
        )
        .animation(.easeInOut(duration: 0.5), value: windowState.mode)
        .animation(.easeInOut(duration: 0.4), value: onboarding.isComplete)
        .animation(.easeInOut(duration: 0.3), value: onboarding.isStateRestored)
        .animation(.easeInOut(duration: 0.2), value: auxiliaryWindows.isApprovalVisible)
    }

    // MARK: - Collapsed View

    /// Full-window orb for the 120x120 collapsed mode.
    private var collapsedView: some View {
        NativeOrbView(
            orbAnimation: orbAnimation,
            audioRMS: pipelineAux.audioRMS,
            windowMode: windowState.mode.rawValue,
            onLoad: { withAnimation(.easeIn(duration: 0.4)) { viewLoaded = true } },
            onOrbClicked: {
                windowState.transitionToCompact()
                NotificationCenter.default.post(
                    name: .faeConversationEngage,
                    object: nil
                )
            },
            onOrbContextMenu: {
                showCollapsedContextMenu()
            }
        )
        .clipShape(Circle())
        .opacity(viewLoaded ? 1 : 0)
    }

    // MARK: - Compact View

    /// Three-zone vertical layout: orb crown, conversation scroll, input bar.
    private var compactView: some View {
        VStack(spacing: 0) {
            // Zone 1: Orb Crown — dedicated 160pt hero section, never covered
            OrbCrownView(
                onLoad: { withAnimation(.easeIn(duration: 0.4)) { viewLoaded = true } }
            )
            .frame(height: 300)

            // Subtle separator
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Zone 2: Conversation — scrolling, fills remaining space
            ConversationScrollView()

            // Subtle separator
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Zone 3: Input — pinned at bottom, hidden until pipeline ready
            if pipelineAux.isPipelineReady {
                InputBarView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(viewLoaded ? 1 : 0)
        .overlay {
            // Emergency stop — visible whenever a tool approval is pending
            if auxiliaryWindows.isApprovalVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { auxiliaryWindows.emergencyStop() }) {
                            Label("Stop", systemImage: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .shadow(color: .red.opacity(0.5), radius: 6)
                        .padding(.trailing, 10)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
    }

    // MARK: - Collapsed Context Menu

    /// Simplified context menu for the collapsed orb (no Reset Conversation —
    /// that lives in the full compact context menu via OrbCrownView).
    private func showCollapsedContextMenu() {
        guard let window = windowState.window,
              let contentView = window.contentView else { return }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: Selector(("showSettingsWindow:")),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.addItem(.separator())

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

        let quitItem = NSMenuItem(
            title: "Quit Fae",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        objc_setAssociatedObject(
            menu, &Self.menuHandlersKey,
            [hideHandler] as NSArray,
            .OBJC_ASSOCIATION_RETAIN
        )

        let mouseLocation = window.mouseLocationOutsideOfEventStream
        menu.popUp(positioning: nil, at: mouseLocation, in: contentView)
    }
}
