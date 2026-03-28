import SwiftUI

/// Tools settings tab: informational capability showcase + Apple permissions.
///
/// The tool mode picker is intentionally hidden — Fae operates in full access
/// for the owner, gated by voice identity, not a settings toggle. This tab
/// instead educates users about what Fae can do and provides quick access to
/// the action history panel.
struct SettingsToolsTab: View {
    @EnvironmentObject private var onboarding: OnboardingController

    var commandSender: HostCommandSender?

    @AppStorage("toolMode") private var toolMode: String = "full"
    @State private var permissionSnapshot = PermissionStatusProvider.current()
    @State private var showResetAlert = false

    var body: some View {
        Form {
            // MARK: Action History
            Section("Action History") {
                Button {
                    NotificationCenter.default.post(name: .faeShowReceiptsPanel, object: nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14))
                            .foregroundStyle(FaeDesign.heatherMistText)
                        Text("View action history\u{2026}")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Text("Every change Fae makes is logged here. Tap any item to undo it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: What Fae Can Do
            Section("What Fae Can Do") {
                capabilityCard(
                    icon: "doc.badge.plus",
                    title: "Reads & writes files",
                    description: "Opens, reads, and saves files anywhere on your Mac."
                )
                capabilityCard(
                    icon: "calendar",
                    title: "Manages Calendar & Reminders",
                    description: "Creates, edits, and deletes events and reminders."
                )
                capabilityCard(
                    icon: "magnifyingglass",
                    title: "Searches the web",
                    description: "Fetches web pages and searches when you ask."
                )
                capabilityCard(
                    icon: "terminal",
                    title: "Runs safe shell commands",
                    description: "Runs echo, cp, mv, mkdir — nothing destructive without your say-so."
                )
                capabilityCard(
                    icon: "person.crop.circle",
                    title: "Contacts & Notes",
                    description: "Reads and updates your contacts and Apple Notes."
                )
                capabilityCard(
                    icon: "clock.arrow.circlepath",
                    title: "Remembers every action",
                    description: "Logs every change so you can undo it with one tap."
                )
            }

            // MARK: Trust & Approvals
            Section("Trust & Approvals") {
                Button("Reset approvals\u{2026}") {
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
                    Text("Fae will ask before acting again \u{2014} like a fresh start.")
                }

                Text("When Fae asks permission, tap Always to build trust over time. Reset clears all remembered approvals.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: Apple Tool Permissions
            Section("Apple Tool Permissions") {
                if !allApplePermissionsGranted {
                    Button("Grant All Apple Permissions") {
                        onboarding.requestCalendar()
                        onboarding.requestReminders()
                        onboarding.requestContacts()
                        onboarding.requestMail()
                        refreshAfterDelay()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Text("Grant access to Calendar, Reminders, Contacts, Mail & Notes all at once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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

    /// True when Calendar, Reminders, and Contacts are all granted.
    /// Mail & Notes use Automation (no preflight API), so excluded from this check.
    private var allApplePermissionsGranted: Bool {
        permissionSnapshot.calendar && permissionSnapshot.reminders && permissionSnapshot.contacts
    }

    // MARK: - Capability Card

    @ViewBuilder
    private func capabilityCard(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(FaeDesign.heatherMistText)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permission Row

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
