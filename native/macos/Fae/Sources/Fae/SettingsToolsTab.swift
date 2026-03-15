import SwiftUI

/// Tools settings tab: simplified two-mode dropdown + reset approvals.
struct SettingsToolsTab: View {
    @EnvironmentObject private var onboarding: OnboardingController

    var commandSender: HostCommandSender?

    @AppStorage("toolMode") private var toolMode: String = "full"
    @State private var permissionSnapshot = PermissionStatusProvider.current()
    @State private var showResetAlert = false

    private let toolModes: [(label: String, value: String, description: String)] = [
        ("Read only", "assistant",
         "Fae can search, read, and recall — she won't modify anything."),
        ("Everything (with approval)", "full",
         "Fae can do everything — she'll ask before acting for the first time."),
    ]

    var body: some View {
        Form {
            Section("Permissions") {
                Picker("Mode", selection: $toolMode) {
                    ForEach(toolModes, id: \.value) { mode in
                        Text(mode.label).tag(mode.value)
                    }
                }
                .onChange(of: toolMode) {
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "tool_mode", "value": toolMode]
                    )
                }

                if let current = toolModes.first(where: { $0.value == toolMode }) {
                    Text(current.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Reset approvals...") {
                    showResetAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert("Reset approvals?", isPresented: $showResetAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Reset", role: .destructive) {
                        Task {
                            await ApprovedToolsStore.shared.revokeAll()
                        }
                    }
                } message: {
                    Text("Fae will ask before acting again — like a fresh start.")
                }

                Text("When Fae asks permission, tap Always to build trust over time. Reset clears all remembered approvals.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Tool Permissions") {
                permissionRow(
                    icon: "calendar",
                    label: "Calendar",
                    granted: permissionSnapshot.calendar,
                    action: {
                        onboarding.requestCalendar()
                        refreshAfterDelay()
                    }
                )

                permissionRow(
                    icon: "checklist",
                    label: "Reminders",
                    granted: permissionSnapshot.reminders,
                    action: {
                        onboarding.requestReminders()
                        refreshAfterDelay()
                    }
                )

                permissionRow(
                    icon: "person.crop.circle",
                    label: "Contacts",
                    granted: permissionSnapshot.contacts,
                    action: {
                        onboarding.requestContacts()
                        refreshAfterDelay()
                    }
                )

                HStack {
                    Label("Mail & Notes", systemImage: "envelope")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Button("Open Settings") {
                        onboarding.requestMail()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("Mail and Notes require Automation access. Grant it in System Settings > Privacy & Security > Automation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About Tools") {
                Text("Tools give Fae the ability to interact with your system — reading files, managing calendar events, sending emails, and more. In Full access mode, Fae asks before doing anything new. Tap Always to let her remember your choice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissionSnapshot = PermissionStatusProvider.current()
            // Migrate legacy tool mode on settings open.
            let migrated = FaeConfig.migrateToolMode(toolMode)
            if migrated != toolMode {
                toolMode = migrated
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func permissionRow(
        icon: String,
        label: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            if granted {
                Text("Granted")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Text("Not Granted")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func refreshAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                permissionSnapshot = PermissionStatusProvider.current()
            }
        }
    }
}
