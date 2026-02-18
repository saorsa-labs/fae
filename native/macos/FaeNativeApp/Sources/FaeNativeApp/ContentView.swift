import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var windowState: WindowStateController
    @StateObject private var onboarding = OnboardingController()
    @State private var viewLoaded = false

    var body: some View {
        ZStack {
            if !onboarding.isComplete {
                onboardingView
                    .transition(.opacity)
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
    }

    // MARK: - Onboarding View

    private var onboardingView: some View {
        OnboardingWebView(
            onLoad: {
                // Onboarding HTML loaded — nothing to push yet on initial load.
            },
            onRequestPermission: { permission in
                switch permission {
                case "microphone":
                    onboarding.requestMicrophone()
                case "contacts":
                    onboarding.requestContacts()
                default:
                    NSLog("ContentView: unknown permission requested: %@", permission)
                }
            },
            onPermissionHelp: { permission in
                // Phase 2.4 wires TTS help audio here.
                NSLog("ContentView: permission help requested for %@", permission)
            },
            onComplete: {
                withAnimation { onboarding.complete() }
            },
            onAdvance: {
                onboarding.advance()
            }
        )
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
                panelSide: windowState.panelSide.rawValue,
                onLoad: { withAnimation(.easeIn(duration: 0.4)) { viewLoaded = true } },
                onUserMessage: { text in
                    conversation.handleUserSent(text)
                    windowState.noteActivity()
                },
                onToggleListening: {
                    conversation.toggleListening()
                    windowState.noteActivity()
                },
                onLinkDetected: { url in conversation.handleLinkDetected(url) },
                onPanelOpened: { panel in windowState.panelOpened(panel) },
                onPanelClosed: { panel in windowState.panelClosed(panel) },
                onUserInteraction: { windowState.noteActivity() },
                onOrbClicked: {
                    if windowState.mode == .collapsed {
                        windowState.transitionToCompact()
                    }
                }
            )
            .opacity(viewLoaded ? 1 : 0)

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
