import SwiftUI

/// About settings tab: version info, onboarding reset, handoff settings.
struct SettingsAboutTab: View {
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var onboarding: OnboardingController
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

            Section("Links") {
                if let websiteURL = URL(string: "https://saorsalabs.com") {
                    Link("Fae Website", destination: websiteURL)
                }
                if let issuesURL = URL(string: "https://github.com/saorsa-labs/fae/issues") {
                    Link("Report an Issue", destination: issuesURL)
                }
                if let privacyURL = URL(string: "https://saorsalabs.com/privacy") {
                    Link("Privacy Policy", destination: privacyURL)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.2"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func resetOnboarding() {
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": "onboarded", "value": false]
        )
        onboarding.isComplete = false
        onboarding.isStateRestored = true
    }
}
