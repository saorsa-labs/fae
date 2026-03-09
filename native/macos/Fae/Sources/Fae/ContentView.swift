import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var orbAnimation: OrbAnimationState
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @EnvironmentObject private var faeCore: FaeCore
    @State private var viewLoaded = false
    @State private var showingNativeEnrollment = false
    @State private var listeningBeforeNativeEnrollment = true

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
        .accessibilityLabel("Fae orb, currently \(orbState.mode.label) and feeling \(orbState.feeling.label)")
        .background(
            NSWindowAccessor { window in
                windowState.window = window
            }
        )
        .animation(.easeInOut(duration: 0.5), value: windowState.mode)
        .animation(.easeInOut(duration: 0.4), value: ownerEnrollmentComplete)
        .animation(.easeInOut(duration: 0.3), value: onboarding.isStateRestored)
        .animation(.easeInOut(duration: 0.2), value: auxiliaryWindows.isApprovalVisible)
        .sheet(isPresented: $showingNativeEnrollment) {
            SpeakerEnrollmentView(
                captureManager: faeCore.nativeEnrollmentCaptureManager,
                speakerEncoder: faeCore.nativeEnrollmentSpeakerEncoder,
                speakerProfileStore: faeCore.nativeEnrollmentSpeakerProfileStore,
                onComplete: { enrolledName in
                    showingNativeEnrollment = false
                    let trimmedName = enrolledName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedName.isEmpty {
                        onboarding.userName = trimmedName
                    }
                    onboarding.isComplete = true
                    restoreConversationAfterNativeEnrollment()
                    faeCore.completeNativeOwnerEnrollment(displayName: enrolledName)
                },
                onCancel: {
                    showingNativeEnrollment = false
                    restoreConversationAfterNativeEnrollment()
                },
                initialName: onboarding.userName ?? faeCore.userName ?? ""
            )
            .preferredColorScheme(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeStartNativeEnrollmentRequested)) { _ in
            windowState.transitionToCompact()
            beginNativeEnrollment()
        }
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

            // Enrollment invitation — visible until owner voice is enrolled.
            if !ownerEnrollmentComplete {
                EnrollmentInvitationBanner {
                    windowState.transitionToCompact()
                    beginNativeEnrollment()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Zone 3: Input — pinned at bottom, always visible so users
            // can type while models load. Text is queued until pipeline starts.
            InputBarView()
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private var ownerEnrollmentComplete: Bool {
        onboarding.isComplete || faeCore.hasOwnerSetUp
    }

    private func beginNativeEnrollment() {
        listeningBeforeNativeEnrollment = conversation.isListening
        NotificationCenter.default.post(name: .faeCancelGeneration, object: nil)
        NotificationCenter.default.post(
            name: .faeConversationGateSet,
            object: nil,
            userInfo: ["active": false]
        )
        showingNativeEnrollment = true
    }

    private func restoreConversationAfterNativeEnrollment() {
        NotificationCenter.default.post(
            name: .faeConversationGateSet,
            object: nil,
            userInfo: ["active": listeningBeforeNativeEnrollment]
        )
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

// MARK: - Enrollment Invitation Banner

/// Shown above the input bar until the owner voice is enrolled.
/// Tapping it triggers the enrollment conversation with Fae.
private struct EnrollmentInvitationBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.person.filled")
                    .font(.system(size: 13))
                    .foregroundStyle(.purple)

                Text("Let me get to know you")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.purple.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
