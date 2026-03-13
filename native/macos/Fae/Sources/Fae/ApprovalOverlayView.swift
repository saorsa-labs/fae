import SwiftUI

/// Compact floating card displayed near the orb for approvals and input requests.
struct ApprovalOverlayView: View {
    @ObservedObject var controller: ApprovalOverlayController

    var body: some View {
        VStack(spacing: 8) {
            if let request = controller.activeInput {
                Group {
                    if request.isForm {
                        FormInputCard(request: request, controller: controller)
                    } else {
                        InputCard(request: request, controller: controller)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            } else if let request = controller.activeToolModeRequest {
                ToolModeCard(request: request, controller: controller)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if let request = controller.activeGovernanceConfirmation {
                GovernanceConfirmationCard(request: request, controller: controller)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if let request = controller.activeApproval {
                Group {
                    if request.isDisasterLevel {
                        DisasterWarningCard(request: request, controller: controller)
                    } else if request.manualOnly {
                        ManualApprovalCard(request: request, controller: controller)
                    } else {
                        ApprovalCard(request: request, controller: controller)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .animation(.spring(duration: 0.3), value: controller.activeApproval?.id)
        .animation(.spring(duration: 0.3), value: controller.activeInput?.id)
        .animation(.spring(duration: 0.3), value: controller.activeToolModeRequest?.id)
        .animation(.spring(duration: 0.3), value: controller.activeGovernanceConfirmation?.id)
    }
}

private struct DismissOverlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
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

            Text("Say no, once, always, always read-only, or always all.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Row 1: Primary actions — No / Once / Always
            HStack(spacing: 8) {
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
                    Text("Once")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: { controller.approveAlways() }) {
                    Text("Always")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }

            // Row 2: Escalation — Always read-only / Always all
            HStack(spacing: 8) {
                Button(action: { controller.approveAllReadOnly() }) {
                    Text("Always read-only")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.teal)

                Button(action: { controller.approveAll() }) {
                    Text("Always all")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .overlay(alignment: .topTrailing) {
            DismissOverlayButton(action: controller.deny)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Governance Confirmation Card

private struct GovernanceConfirmationCard: View {
    let request: ApprovalOverlayController.GovernanceConfirmationRequest
    let controller: ApprovalOverlayController

    var body: some View {
        VStack(spacing: 10) {
            Text(request.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(request.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("Use the popup to confirm. Settings are for review and revocation.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button(action: { controller.denyGovernanceRequest() }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: { controller.confirmGovernanceRequest() }) {
                    Text(request.confirmLabel)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .overlay(alignment: .topTrailing) {
            DismissOverlayButton(action: controller.denyGovernanceRequest)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Tool Mode Card

private struct ToolModeCard: View {
    let request: ApprovalOverlayController.ToolModeRequest
    let controller: ApprovalOverlayController

    private var title: String {
        if request.reason.contains("owner_enrollment_required") {
            return "Owner Enrollment Required"
        }
        if request.reason.contains("non-owner") {
            return "Speaker Not Authorized"
        }
        return "Tool Access Required"
    }

    private var message: String {
        if request.reason.contains("owner_enrollment_required") {
            return "Enroll your voice to enable tool access."
        }
        if request.reason.contains("non-owner") {
            return "Owner-gated tools are blocked for this speaker."
        }
        return "I need tool access to help with this request."
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if request.reason.contains("owner_enrollment_required") {
                // Enrollment case: Dismiss / Start Enrollment
                HStack(spacing: 8) {
                    Button(action: { controller.dismissToolModeRequest() }) {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: { controller.requestEnrollment() }) {
                        Text("Start Enrollment")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .keyboardShortcut(.return, modifiers: [])
                }
            } else if request.reason.contains("non-owner") {
                // Non-owner case: Dismiss / Read-Only
                HStack(spacing: 8) {
                    Button(action: { controller.dismissToolModeRequest() }) {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: { controller.upgradeToolMode("read_only") }) {
                        Text("Read-Only")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .keyboardShortcut(.return, modifiers: [])
                }
            } else {
                // Tools off / general case: progressive allow
                HStack(spacing: 8) {
                    Button(action: { controller.dismissToolModeRequest() }) {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: { controller.upgradeToolMode("read_write") }) {
                        Text("Read & Write")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)

                    Button(action: { controller.upgradeToolMode("full") }) {
                        Text("Full Access")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .overlay(alignment: .topTrailing) {
            DismissOverlayButton(action: controller.dismissToolModeRequest)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Manual Approval Card (damage-control confirm_manual tier)

/// Standard manual-only confirmation. No voice hint, no "Always" / "Allow All".
/// Used when the operation is dangerous but has legitimate uses (sudo delete, pipe-shell, etc.).
private struct ManualApprovalCard: View {
    let request: ApprovalOverlayController.ApprovalRequest
    let controller: ApprovalOverlayController

    var body: some View {
        VStack(spacing: 10) {
            Text("Manual Approval Required")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)

            Text(request.description)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("This operation requires a deliberate button press. Voice approval is not accepted.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
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
                    Text("Proceed")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) {
            DismissOverlayButton(action: controller.deny)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .orange.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Disaster Warning Card (damage-control disaster tier)

/// Extreme manual-only overlay for catastrophic, irreversible operations.
/// Red border, bold DISASTER WARNING header. No voice, no "Always", no timeout.
/// Only a deliberate physical click on "Proceed Anyway" can approve.
private struct DisasterWarningCard: View {
    let request: ApprovalOverlayController.ApprovalRequest
    let controller: ApprovalOverlayController

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.red)

                Text("DISASTER WARNING")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.red)
            }

            Text(request.description)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("This operation is IRREVERSIBLE. Voice approval is not accepted.\nOnly click \"Proceed Anyway\" if you are absolutely certain.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red.opacity(0.85))
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button(action: { controller.deny() }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: { controller.approve() }) {
                    Text("Proceed Anyway")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.red.opacity(0.8), lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .red.opacity(0.2), radius: 12, y: 6)
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
    private static let cardFill = Color(red: 28 / 255, green: 31 / 255, blue: 40 / 255).opacity(0.96)
    private static let cardStroke = Color.white.opacity(0.08)

    private var field: ApprovalOverlayController.InputField {
        request.fields.first ?? .init(
            id: "text",
            label: "Value",
            placeholder: "",
            isSecure: false,
            required: true,
            minLength: nil,
            maxLength: nil,
            regex: nil,
            allowedValues: nil,
            mustBeHttps: false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Self.heather)
                Text(request.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(request.prompt)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if field.isSecure {
                    SecureField(
                        field.placeholder.isEmpty ? "Enter value…" : field.placeholder,
                        text: $inputText
                    )
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { submitIfValid() }
                } else if field.isMultiline {
                    ZStack(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text(field.placeholder.isEmpty ? "Paste or type here…" : field.placeholder)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $inputText)
                            .font(.system(size: 13, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .focused($isFocused)
                    }
                    .frame(height: 100)
                } else {
                    TextField(
                        field.placeholder.isEmpty ? "Enter value…" : field.placeholder,
                        text: $inputText
                    )
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { submitIfValid() }
                }
            }
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
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: field.isMultiline ? [.command] : [])
            }

            if field.isMultiline {
                Text("⌘Return to submit")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(width: field.isMultiline ? 340 : 260)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Self.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Self.cardStroke, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .overlay(alignment: .topTrailing) {
            DismissOverlayButton(action: controller.cancelInput)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .onAppear { isFocused = true }
    }

    private func submitIfValid() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.submitInput(text: trimmed)
    }
}

private struct FormInputCard: View {
    let request: ApprovalOverlayController.InputRequest
    let controller: ApprovalOverlayController

    @State private var values: [String: String] = [:]
    @State private var validationMessage: String?

    /// Heather accent colour.
    private static let heather = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)
    private static let cardFill = Color(red: 28 / 255, green: 31 / 255, blue: 40 / 255).opacity(0.96)
    private static let cardStroke = Color.white.opacity(0.08)

    private var hasMultilineField: Bool {
        request.fields.contains { $0.isMultiline }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundColor(Self.heather)
                Text(request.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(request.prompt)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    Group {
                        if field.isSecure {
                            SecureField(
                                field.placeholder.isEmpty ? field.label : field.placeholder,
                                text: binding(for: field.id)
                            )
                            .textFieldStyle(.plain)
                        } else if field.isMultiline {
                            ZStack(alignment: .topLeading) {
                                if (values[field.id] ?? "").isEmpty {
                                    Text(field.placeholder.isEmpty ? "Paste or type here…" : field.placeholder)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 8)
                                }
                                TextEditor(text: binding(for: field.id))
                                    .font(.system(size: 13, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                            }
                            .frame(height: 100)
                        } else {
                            TextField(
                                field.placeholder.isEmpty ? field.label : field.placeholder,
                                text: binding(for: field.id)
                            )
                            .textFieldStyle(.plain)
                        }
                    }
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
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                .keyboardShortcut(.return, modifiers: hasMultilineField ? [.command] : [])
            }

            if hasMultilineField {
                Text("⌘Return to submit")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(width: hasMultilineField ? 340 : 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Self.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Self.cardStroke, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .overlay(alignment: .topTrailing) {
            DismissOverlayButton(action: controller.cancelInput)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
    }

    private var firstValidationError: String? {
        for field in request.fields {
            let value = values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if field.required && value.isEmpty {
                return "\(field.label) is required."
            }
            if let minLength = field.minLength, !value.isEmpty, value.count < minLength {
                return "\(field.label) must be at least \(minLength) characters."
            }
            if let maxLength = field.maxLength, value.count > maxLength {
                return "\(field.label) must be at most \(maxLength) characters."
            }
            if let allowed = field.allowedValues, !allowed.isEmpty,
               !value.isEmpty,
               !allowed.contains(value)
            {
                return "\(field.label) must be one of: \(allowed.joined(separator: ", "))."
            }
            if field.mustBeHttps,
               !value.isEmpty,
               !value.lowercased().hasPrefix("https://")
            {
                return "\(field.label) must start with https://"
            }
            if let pattern = field.regex,
               !pattern.isEmpty,
               !value.isEmpty,
               let regex = try? NSRegularExpression(pattern: pattern)
            {
                let range = NSRange(value.startIndex..., in: value)
                if regex.firstMatch(in: value, options: [], range: range) == nil {
                    return "\(field.label) has an invalid format."
                }
            }
        }
        return nil
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { values[id, default: ""] },
            set: {
                values[id] = $0
                validationMessage = nil
            }
        )
    }

    private func submitIfValid() {
        if let firstValidationError {
            validationMessage = firstValidationError
            return
        }

        var sanitized: [String: String] = [:]
        for field in request.fields {
            let value = values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                sanitized[field.id] = value
            }
        }
        controller.submitForm(values: sanitized)
    }
}
