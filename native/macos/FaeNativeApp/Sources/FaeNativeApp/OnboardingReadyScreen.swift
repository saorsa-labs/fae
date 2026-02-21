import SwiftUI

/// Ready screen — final phase of the native onboarding flow.
///
/// Shows a personalised greeting using the user's name (if contacts
/// permission was granted), a listening indicator, and a "Start conversation"
/// CTA that completes onboarding.
struct OnboardingReadyScreen: View {
    var userName: String?
    var onComplete: () -> Void

    @State private var bubbleVisible = false
    @State private var buttonVisible = false
    @State private var listeningPulse = false

    private var greeting: String {
        if let name = userName, !name.isEmpty {
            return "Hello, \(name). I\u{2019}m all set \u{2014} just speak or type whenever you\u{2019}re ready. I\u{2019}m here."
        }
        return "I\u{2019}m all set \u{2014} just speak or type whenever you\u{2019}re ready. I\u{2019}m here."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Speech bubble.
            VStack(spacing: 12) {
                Text(greeting)
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

            Spacer().frame(height: 24)

            // Listening indicator.
            HStack(spacing: 6) {
                Circle()
                    .fill(.green.opacity(0.8))
                    .frame(width: 8, height: 8)
                    .scaleEffect(listeningPulse ? 1.3 : 0.9)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: listeningPulse
                    )
                Text("Listening")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .opacity(buttonVisible ? 1 : 0)

            Spacer().frame(height: 32)

            // CTA button.
            Button(action: onComplete) {
                Text("Start conversation")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.706, green: 0.659, blue: 0.769).opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .opacity(buttonVisible ? 1 : 0)

            Spacer().frame(height: 40)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.3)) {
                bubbleVisible = true
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.8)) {
                buttonVisible = true
            }
            // Start listening pulse.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                listeningPulse = true
            }
        }
    }
}
