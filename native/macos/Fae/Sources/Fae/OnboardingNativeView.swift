import SwiftUI

/// Native onboarding container view — replaces `OnboardingWebView` (Phase 3).
///
/// Renders the Metal fog-cloud orb as a background (auto-cycling Scottish
/// palettes), with three phase screens sliding in/out:
///   1. Welcome — greeting + "Get started"
///   2. Permissions — 4 system permission cards
///   3. Ready — personalised greeting + "Start conversation"
///
/// The orb background cycles through Scottish palettes for a warm, inviting
/// aesthetic during onboarding.
struct OnboardingNativeView: View {
    @ObservedObject var onboarding: OnboardingController
    var onPermissionHelp: (String) -> Void

    /// Orb animation state for the background orb (auto-cycling palettes).
    @StateObject private var orbAnimation = OrbAnimationState()
    /// Orb state controller for palette cycling.
    @StateObject private var orbState = OrbStateController()

    @State private var currentPhase: OnboardingPhase
    @State private var paletteCycleIndex = 0

    /// Scottish palettes to cycle through during onboarding.
    private static let cyclingPalettes: [OrbPalette] = [
        .heatherMist, .dawnLight, .lochGreyGreen,
        .autumnBracken, .rowanBerry, .mossStone,
        .silverMist, .peatEarth, .glenGreen,
    ]

    init(
        onboarding: OnboardingController,
        onPermissionHelp: @escaping (String) -> Void
    ) {
        self.onboarding = onboarding
        self.onPermissionHelp = onPermissionHelp
        _currentPhase = State(initialValue: onboarding.typedInitialPhase)
    }

    var body: some View {
        ZStack {
            // Orb background — shifted upward so the bright core sits
            // in the upper third, above the speech bubble and CTA.
            // Hit testing disabled so the OrbClickTarget overlay doesn't
            // consume mouse events meant for phase-screen buttons.
            NativeOrbView(
                orbAnimation: orbAnimation,
                audioRMS: 0,
                windowMode: "compact"
            )
            .allowsHitTesting(false)
            .offset(y: -70)
            .ignoresSafeArea()

            // Phase content.
            Group {
                switch currentPhase {
                case .welcome:
                    OnboardingWelcomeScreen(onAdvance: advancePhase)
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                case .permissions:
                    OnboardingPermissionsScreen(
                        onboarding: onboarding,
                        onPermissionHelp: onPermissionHelp,
                        onAdvance: advancePhase
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))

                case .ready:
                    OnboardingReadyScreen(
                        userName: onboarding.userName,
                        onComplete: { onboarding.complete() }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: currentPhase)

            // Phase dots.
            VStack {
                Spacer()
                phaseDots
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            orbAnimation.bind(to: orbState)
            startPaletteCycling()
        }
    }

    // MARK: - Phase Navigation

    private func advancePhase() {
        guard let next = currentPhase.next else { return }
        onboarding.advance()
        currentPhase = next
    }

    // MARK: - Phase Dots

    private var phaseDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPhase.allCases, id: \.rawValue) { phase in
                Circle()
                    .fill(phase == currentPhase
                        ? Color.white.opacity(0.8)
                        : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Palette Cycling

    /// Cycles through Scottish palettes every ~6.7 seconds for the orb background.
    private func startPaletteCycling() {
        cyclePalette()
    }

    private func cyclePalette() {
        let palette = Self.cyclingPalettes[paletteCycleIndex % Self.cyclingPalettes.count]
        orbState.palette = palette
        paletteCycleIndex += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.7) { [self] in
            cyclePalette()
        }
    }
}
