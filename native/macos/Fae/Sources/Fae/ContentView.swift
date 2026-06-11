import AppKit
import SwiftUI

/// Reduced companion window content.
///
/// The Rust orb host is the product UI. This window survives only as the
/// text-input companion surface ("Ask Fae"), the onboarding/enrollment host,
/// and the startup holding view. It stays hidden while the orb host runs and
/// is surfaced only by explicit user actions (Ask Fae, global hotkey).
struct ContentView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var subtitles: SubtitleStateController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @EnvironmentObject private var faeCore: FaeCore

    var body: some View {
        VStack(spacing: 0) {
            if pipelineAux.isPipelineReady {
                // Voice hints — collapsible cheat sheet for wake/silence phrases.
                VoiceHintsView()

                // Conversation — scrolling, fills remaining space.
                ConversationScrollView()

                // Subtle separator
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)

                // Voice/photo enrollment banners removed (S18 push-to-talk era):
                // identity is the deliberate physical act at the machine, not a
                // voiceprint. Enrollment remains reachable from Settings >
                // Speaker until the full voice-identity teardown lands.

                // Input — pinned at bottom once startup fully completes.
                InputBarView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                startupHoldingView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            NSWindowAccessor { window in
                windowState.window = window
            }
        )
        .animation(.easeInOut(duration: 0.3), value: onboarding.isStateRestored)
        .animation(.easeInOut(duration: 0.2), value: auxiliaryWindows.isApprovalVisible)
        .overlay {
            // Emergency stop — visible whenever a tool approval is pending
            if auxiliaryWindows.isApprovalVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { auxiliaryWindows.emergencyStop() }) {
                            Label("Stop", systemImage: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(FaeDesign.rowanBerry)
                        .clipShape(Capsule())
                        .shadow(color: FaeDesign.rowanBerry.opacity(0.5), radius: 6)
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

    private var startupHoldingView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Color.primary.opacity(0.45))

            Text("Fae is starting")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundColor(.primary.opacity(0.88))

            Text(startupDetailText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 320)

            Text("The conversation surface unlocks when downloads, model loading, and warmup are complete.")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.primary.opacity(0.42))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 360)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var startupDetailText: String {
        if !subtitles.progressLabel.isEmpty {
            return subtitles.progressLabel
        }
        if !pipelineAux.status.isEmpty {
            return pipelineAux.status
        }
        return "Loading local components…"
    }

}

// MARK: - Menu Action Handler

/// Retained Objective-C target for programmatic `NSMenuItem` actions.
final class MenuActionHandler: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}
