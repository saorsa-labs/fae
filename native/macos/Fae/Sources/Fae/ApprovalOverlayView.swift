import SwiftUI

/// Compact floating approval card displayed near the orb.
///
/// Shows the tool name, a brief description, and Yes/No buttons.
/// Semi-transparent background, slide-in animation, auto-dismissed
/// when the approval resolves (voice, button, or timeout).
struct ApprovalOverlayView: View {
    @ObservedObject var controller: ApprovalOverlayController

    var body: some View {
        if let request = controller.activeApproval {
            VStack(spacing: 10) {
                // Tool name header
                Text("Permission Required")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                // Description
                Text(request.description)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                // Buttons
                HStack(spacing: 12) {
                    Button(action: { controller.deny() }) {
                        Text("No")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: { controller.approve() }) {
                        Text("Yes")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(14)
            .frame(width: 240)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
        }
    }
}
