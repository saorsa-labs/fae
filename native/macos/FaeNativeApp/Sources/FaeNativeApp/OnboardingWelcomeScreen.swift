import SwiftUI

/// Welcome screen — first phase of the native onboarding flow.
///
/// Displays the animated orb (rendered by the parent view's background),
/// a speech bubble greeting from Fae, and a "Get started" CTA button.
/// Clicking anywhere or pressing the button advances to the Permissions phase.
struct OnboardingWelcomeScreen: View {
    var onAdvance: () -> Void

    @State private var bubbleVisible = false
    @State private var buttonVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Speech bubble.
            VStack(spacing: 12) {
                Text("Hello. I\u{2019}m Fae \u{2014} your private, always-available AI companion. Everything I do happens right here on your Mac.")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .opacity(0.85)
            )
            .padding(.horizontal, 40)
            .opacity(bubbleVisible ? 1 : 0)
            .offset(y: bubbleVisible ? 0 : 12)

            Spacer().frame(height: 32)

            // CTA button.
            Button(action: onAdvance) {
                Text("Get started")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.706, green: 0.659, blue: 0.769).opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .opacity(buttonVisible ? 1 : 0)

            Spacer().frame(height: 16)

            // Hint text.
            Text("click anywhere to continue")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .opacity(buttonVisible ? 1 : 0)

            Spacer().frame(height: 40)
        }
        .contentShape(Rectangle())
        .onTapGesture { onAdvance() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.4)) {
                bubbleVisible = true
            }
            withAnimation(.easeOut(duration: 0.6).delay(1.0)) {
                buttonVisible = true
            }
        }
    }
}
