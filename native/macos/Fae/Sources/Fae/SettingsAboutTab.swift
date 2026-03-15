import SwiftUI

/// About settings tab: version info, onboarding reset, handoff settings.
struct SettingsAboutTab: View {
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var conversation: ConversationController
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var resetError: String?
    let commandSender: HostCommandSender?

    var body: some View {
        Form {
            Section("About Fae") {
                HStack {
                    Text("Version")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(appVersion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(appBuild)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Model")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(conversation.loadedModelLabel.isEmpty ? "Loading\u{2026}" : conversation.loadedModelLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("by Saorsa Labs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Onboarding") {
                Button("Re-run Onboarding") {
                    resetOnboarding()
                }
                .buttonStyle(.bordered)
                Text("Resets onboarding state so you can walk through setup again on next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                Button("Reset Fae Data…") {
                    showResetConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .disabled(isResetting)
                Text("Choose between a normal reset or a full erase that also removes Fae's backup vault. Downloaded models are kept.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Note: deleted files are removed from their normal locations but cannot be securely erased from the drive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isResetting {
                    ProgressView("Resetting Fae data…")
                        .controlSize(.small)
                }
                if let resetError {
                    Text(resetError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog("Reset Fae data", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Reset App Data", role: .destructive) {
                    resetAppData()
                }
                Button("Erase All Fae Data Including Vault", role: .destructive) {
                    eraseAllFaeData()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Reset App Data removes conversations, memories, settings, skills, and stored credentials. The full erase also deletes Fae's backup vault. Downloaded models are not deleted.")
            }

            Section("Cross-Device Handoff") {
                Toggle("Enable Handoff", isOn: $handoff.handoffEnabled)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("Transfer conversations between your Apple devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if handoff.handoffEnabled {
                    HStack {
                        Image(systemName: handoff.currentTarget.systemImage)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current: \(handoff.currentTarget.label)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(handoff.handoffStateText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityLabel("Current device: \(handoff.currentTarget.label)")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .faeDataResetCompleted)) { _ in
            isResetting = false
            resetError = nil
            NSApplication.shared.terminate(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeDataResetFailed)) { notification in
            isResetting = false
            resetError = notification.userInfo?["error"] as? String ?? "Reset failed."
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func resetAppData() {
        isResetting = true
        resetError = nil
        commandSender?.sendCommand(name: "data.delete_all", payload: ["include_vault": false])
    }

    private func eraseAllFaeData() {
        isResetting = true
        resetError = nil
        commandSender?.sendCommand(name: "data.delete_all", payload: ["include_vault": true])
    }

    private func resetOnboarding() {
        commandSender?.sendCommand(
            name: "onboarding.reset",
            payload: [:]
        )
        onboarding.isComplete = false
        // Toggle isStateRestored off then back on so SwiftUI's
        // .onChange(of: isStateRestored) fires even if it was already true.
        // Without this, the onboarding window never re-appears and the user
        // sees a blank black screen.
        onboarding.isStateRestored = false
        DispatchQueue.main.async {
            onboarding.isStateRestored = true
        }
    }
}
