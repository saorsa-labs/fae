import SwiftUI

/// Permissions screen — second phase of the native onboarding flow.
///
/// Displays four permission cards (microphone, contacts, calendar, mail)
/// with animated state transitions, a privacy assurance banner, and a
/// "Continue" CTA. Each card has an Allow button that triggers the
/// corresponding native macOS permission dialog.
struct OnboardingPermissionsScreen: View {
    @ObservedObject var onboarding: OnboardingController
    var onPermissionHelp: (String) -> Void
    var onAdvance: () -> Void

    @State private var contentVisible = false

    private struct PermissionInfo: Identifiable {
        let id: String
        let icon: String
        let name: String
        let description: String
    }

    private let permissions: [PermissionInfo] = [
        PermissionInfo(
            id: "microphone",
            icon: "\u{1F399}\u{FE0F}",
            name: "Microphone",
            description: "Hear your voice for conversation"
        ),
        PermissionInfo(
            id: "contacts",
            icon: "\u{1F464}",
            name: "Contacts",
            description: "Know your name for personalisation"
        ),
        PermissionInfo(
            id: "calendar",
            icon: "\u{1F4C5}",
            name: "Calendar & Reminders",
            description: "Help manage your schedule"
        ),
        PermissionInfo(
            id: "mail",
            icon: "\u{2709}\u{FE0F}",
            name: "Mail & Notes",
            description: "Help find and compose messages"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 50)

            // Title.
            Text("A few things to set up")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.95))

            Text("These help Fae work naturally with you")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 6)

            Spacer().frame(height: 24)

            // Permission cards.
            VStack(spacing: 10) {
                ForEach(permissions) { perm in
                    permissionCard(perm)
                }
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 16)

            // Privacy banner.
            HStack(spacing: 6) {
                Text("\u{1F512}")
                    .font(.system(size: 12))
                Text("Everything stays on your Mac. I never send data anywhere.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Continue button.
            Button(action: onAdvance) {
                Text("Continue")
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

            // Skip hint.
            Text("You can set these up later in Settings")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 8)

            Spacer().frame(height: 40)
        }
        .opacity(contentVisible ? 1 : 0)
        .offset(y: contentVisible ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                contentVisible = true
            }
        }
    }

    // MARK: - Permission Card

    @ViewBuilder
    private func permissionCard(_ perm: PermissionInfo) -> some View {
        let state = onboarding.permissionStates[perm.id] ?? "pending"

        HStack(spacing: 12) {
            // Icon.
            Text(perm.icon)
                .font(.system(size: 24))
                .frame(width: 36)

            // Name and description.
            VStack(alignment: .leading, spacing: 2) {
                Text(perm.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(perm.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Help button.
            Button(action: { onPermissionHelp(perm.id) }) {
                Text("?")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            // Status button.
            statusButton(for: perm.id, state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(state == "granted" ? 0.95 : 0.7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    state == "granted"
                        ? Color.green.opacity(0.3)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func statusButton(for permission: String, state: String) -> some View {
        switch state {
        case "granted":
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text("Granted")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.green.opacity(0.9))
            .frame(width: 80)

        case "denied":
            Text("Denied")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red.opacity(0.8))
                .frame(width: 80)

        case "settings":
            Button(action: { requestPermission(permission) }) {
                Text("Open Settings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)

        default:
            Button(action: { requestPermission(permission) }) {
                Text("Allow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 0.706, green: 0.659, blue: 0.769).opacity(0.5)))
            }
            .buttonStyle(.plain)
        }
    }

    private func requestPermission(_ permission: String) {
        switch permission {
        case "microphone":
            onboarding.requestMicrophone()
        case "contacts":
            onboarding.requestContacts()
        case "calendar":
            onboarding.requestCalendar()
        case "mail":
            onboarding.requestMail()
        default:
            break
        }
    }
}
