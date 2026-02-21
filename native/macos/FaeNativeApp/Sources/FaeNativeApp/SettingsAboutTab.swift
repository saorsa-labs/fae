import SwiftUI

/// About settings tab: version info, updates, onboarding reset, handoff settings.
struct SettingsAboutTab: View {
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var onboarding: OnboardingController
    @State private var showResetConfirmation = false
    let commandSender: HostCommandSender?
    let sparkleUpdater: SparkleUpdaterController?

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

            if let updater = sparkleUpdater, updater.isConfigured {
                Section("Updates") {
                    HStack {
                        Button("Check for Updates") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                        .buttonStyle(.bordered)

                        Spacer()

                        if let lastCheck = updater.lastUpdateCheck {
                            Text("Last checked \(lastCheck, style: .relative) ago")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Automatic Updates", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                    Text("Fae checks for updates every 6 hours and notifies you when one is available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                Button("Reset Fae...") {
                    showResetConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                Text("Deletes all conversations, memories, settings, cached models, and stored credentials. Fae will quit and start fresh on next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .alert("Reset Fae?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All Data", role: .destructive) {
                    resetAllData()
                }
            } message: {
                Text("This will permanently delete all your data including conversations, memories, voice recordings, settings, and credentials. This cannot be undone.")
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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func resetAllData() {
        commandSender?.sendCommand(name: "data.delete_all", payload: [:])
        // Give the backend a moment to finish deletion, then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func resetOnboarding() {
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": "onboarded", "value": false]
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
