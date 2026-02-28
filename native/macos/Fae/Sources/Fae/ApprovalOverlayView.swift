import SwiftUI

/// Compact floating card displayed near the orb for approvals and input requests.
struct ApprovalOverlayView: View {
    @ObservedObject var controller: ApprovalOverlayController

    var body: some View {
        VStack(spacing: 8) {
            if let request = controller.activeInput {
                InputCard(request: request, controller: controller)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if let request = controller.activeApproval {
                ApprovalCard(request: request, controller: controller)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(duration: 0.3), value: controller.activeApproval?.id)
        .animation(.spring(duration: 0.3), value: controller.activeInput?.id)
    }
}

// MARK: - Approval Card

private struct ApprovalCard: View {
    let request: ApprovalOverlayController.ApprovalRequest
    let controller: ApprovalOverlayController

    var body: some View {
        VStack(spacing: 10) {
            Text("Permission Required")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(request.description)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

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
    }
}

// MARK: - Input Card

private struct InputCard: View {
    let request: ApprovalOverlayController.InputRequest
    let controller: ApprovalOverlayController

    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    /// Heather accent colour.
    private static let heather = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Self.heather)
                Text("Fae needs your input")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // Prompt
            Text(request.prompt)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Input field
            Group {
                if request.isSecure {
                    SecureField(
                        request.placeholder.isEmpty ? "Enter value…" : request.placeholder,
                        text: $inputText
                    )
                } else {
                    TextField(
                        request.placeholder.isEmpty ? "Enter value…" : request.placeholder,
                        text: $inputText
                    )
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? Self.heather.opacity(0.5) : Color.primary.opacity(0.15),
                        lineWidth: 1
                    )
            )
            .focused($isFocused)
            .onSubmit { submitIfValid() }

            // Buttons
            HStack(spacing: 10) {
                Button(action: { controller.cancelInput() }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: { submitIfValid() }) {
                    Text("Submit")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.heather)
                .disabled(inputText.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onAppear { isFocused = true }
    }

    private func submitIfValid() {
        guard !inputText.isEmpty else { return }
        controller.submitInput(text: inputText)
    }
}
