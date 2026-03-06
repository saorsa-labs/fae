import SwiftUI

/// Tools settings tab: control tool mode for the embedded agent.
struct SettingsToolsTab: View {
    @EnvironmentObject private var onboarding: OnboardingController

    var commandSender: HostCommandSender?

    @AppStorage("toolMode") private var toolMode: String = "full"
    @State private var autonomyProfile: String = "balanced"
    @State private var showAdvanced = false
    @State private var permissionSnapshot = PermissionStatusProvider.current()
    @State private var toolSnapshot: ToolPermissionSnapshot?
    @State private var approvedTools: [String] = []
    @State private var approveAllReadonly: Bool = false
    @State private var approveAllEnabled: Bool = false
    @State private var disabledTools: Set<String> = []

    private let toolModes: [(label: String, value: String, description: String)] = [
        ("Off", "off", "Tools disabled. LLM-only conversational mode."),
        ("Read Only", "read_only", "Safe defaults: read files, search, list directories."),
        ("Read/Write", "read_write", "Adds file writing and editing capabilities."),
        ("Full", "full", "All tools with approval prompts before dangerous actions."),
        ("Full (No Approval)", "full_no_approval", "All tools without confirmation prompts."),
    ]

    private let autonomyProfiles: [(label: String, value: String, description: String)] = [
        ("Balanced", "balanced", "Recommended: autonomous for routine work, confirms risky actions."),
        ("More autonomous", "autonomous", "Fewer interruptions; still keeps hard safety boundaries."),
        ("More cautious", "cautious", "More confirmations before impactful actions."),
    ]

    var body: some View {
        Form {
            Section("Autonomy Style") {
                Picker("Style", selection: $autonomyProfile) {
                    ForEach(autonomyProfiles, id: \.value) { profile in
                        Text(profile.label).tag(profile.value)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: autonomyProfile) {
                    let mapped = toolMode(forAutonomyProfile: autonomyProfile)
                    if mapped != toolMode {
                        toolMode = mapped
                    }
                }

                if let current = autonomyProfiles.first(where: { $0.value == autonomyProfile }) {
                    Text(current.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Advanced") {
                DisclosureGroup("Raw Tool Mode", isExpanded: $showAdvanced) {
                    Picker("Mode", selection: $toolMode) {
                        ForEach(toolModes, id: \.value) { mode in
                            Text(mode.label).tag(mode.value)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .onChange(of: toolMode) {
                        autonomyProfile = autonomyProfile(forToolMode: toolMode)
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
                }

                Text("Most people should use Autonomy Style above. Raw tool mode is for expert troubleshooting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Current Tool Snapshot") {
                if let snapshot = toolSnapshot {
                    HStack {
                        Text("Allowed tools")
                        Spacer()
                        Text("\(snapshot.allowedTools.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Blocked in mode")
                        Spacer()
                        Text("\(snapshot.deniedTools.count)")
                            .foregroundStyle(.secondary)
                    }
                    Text("Mode \(snapshot.toolMode) · Policy \(snapshot.policyProfile) · Owner gate \(snapshot.ownerGateEnabled ? "on" : "off")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Snapshot") {
                    refreshToolSnapshot()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Say “show tools and permissions” any time to open this snapshot in the canvas with quick mode actions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Per-Tool Availability") {
                Text("Use these toggles to hide or hard-disable individual tools. Tool mode and privacy mode still apply on top.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(groupedTools.keys.sorted(), id: \.self) { category in
                    DisclosureGroup(category) {
                        ForEach(groupedTools[category] ?? [], id: \.name) { tool in
                            toolToggleRow(tool)
                        }
                    }
                }
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

            Section("Tool Approvals") {
                Toggle("Allow All Read-Only", isOn: $approveAllReadonly)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .onChange(of: approveAllReadonly) {
                        refreshToolSnapshot()
                        Task { await ApprovedToolsStore.shared.setApproveAllReadonly(approveAllReadonly) }
                    }
                Text("Auto-approve all low-risk tools (read, search, list).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Allow All In Current Mode", isOn: $approveAllEnabled)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .onChange(of: approveAllEnabled) {
                        refreshToolSnapshot()
                        Task { await ApprovedToolsStore.shared.setApproveAll(approveAllEnabled) }
                    }
                Text("Skip approval popups for any tool already allowed by the current tool mode. File checkpoints still apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !approvedTools.isEmpty {
                    ForEach(approvedTools, id: \.self) { tool in
                        HStack {
                            Text(tool)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            Spacer()
                            Button("Revoke") {
                                Task {
                                    await ApprovedToolsStore.shared.revokeTool(tool)
                                    await refreshApprovalState()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                }

                Button("Revoke All") {
                    Task {
                        await ApprovedToolsStore.shared.revokeAll()
                        await refreshApprovalState()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(approvedTools.isEmpty && !approveAllReadonly && !approveAllEnabled)

                Text("Popup approvals granted via \"Always\" or the global allow toggles appear here. Revoke any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About Tools") {
                Text("Tools give Fae the ability to interact with your system — reading files, managing calendar events, sending emails, and more. The tool mode controls the maximum capability level.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissionSnapshot = PermissionStatusProvider.current()
            autonomyProfile = autonomyProfile(forToolMode: toolMode)
            disabledTools = ToolToggleStore.disabledToolNames()
            refreshToolSnapshot()
            Task { await refreshApprovalState() }
        }
        .onChange(of: toolMode) {
            refreshToolSnapshot()
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

    private var groupedTools: [String: [any Tool]] {
        Dictionary(grouping: ToolRegistry.buildDefault().allTools) {
            CoworkToolSummary.category(for: $0.name)
        }
        .mapValues { group in
            group.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private func toolToggleRow(_ tool: any Tool) -> some View {
        let config = FaeConfig.load()
        let registry = ToolRegistry.buildDefault()
        let disabledByUser = disabledTools.contains(tool.name)
        let allowedByMode = registry.isToolAllowed(tool.name, mode: toolMode, privacyMode: config.privacy.mode)
            || (!ToolToggleStore.isToolEnabled(tool.name) && !disabledByUser)
        let effectiveEnabled = !disabledByUser && allowedByMode

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CoworkToolSummary.displayName(for: tool.name))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(tool.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { !disabledByUser },
                        set: { newValue in
                            ToolToggleStore.setToolEnabled(newValue, for: tool.name)
                            disabledTools = ToolToggleStore.disabledToolNames()
                            refreshToolSnapshot()
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                Text(tool.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(tool.riskLevel.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if disabledByUser {
                    Text("Disabled here")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if !effectiveEnabled {
                    Text("Blocked by mode/privacy")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Available")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func autonomyProfile(forToolMode mode: String) -> String {
        switch mode {
        case "full_no_approval":
            return "autonomous"
        case "off", "read_only", "read_write":
            return "cautious"
        default:
            return "balanced"
        }
    }

    private func toolMode(forAutonomyProfile profile: String) -> String {
        switch profile {
        case "autonomous":
            return "full_no_approval"
        case "cautious":
            return "read_write"
        default:
            return "full"
        }
    }

    private func refreshAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                permissionSnapshot = PermissionStatusProvider.current()
                refreshToolSnapshot()
            }
        }
    }

    @MainActor
    private func refreshApprovalState() async {
        let store = ApprovedToolsStore.shared
        approvedTools = await store.approvedToolNames()
        approveAllReadonly = await store.isApproveAllReadonly()
        approveAllEnabled = await store.isApproveAll()
        refreshToolSnapshot()
    }

    private func refreshToolSnapshot() {
        let config = FaeConfig.load()
        let registry = ToolRegistry.buildDefault()
        let approvalSnapshot = ApprovedToolsStore.ApprovalSnapshot(
            approvedTools: approvedTools,
            approveAllReadonly: approveAllReadonly,
            approveAll: approveAllEnabled
        )
        toolSnapshot = CapabilitySnapshotService.buildSnapshot(
            triggerText: "settings.tools",
            toolMode: toolMode,
            privacyMode: config.privacy.mode,
            speakerState: "Speaker unknown",
            ownerGateEnabled: config.speaker.requireOwnerForTools,
            ownerProfileExists: false,
            permissions: permissionSnapshot,
            thinkingEnabled: config.llm.thinkingEnabled,
            bargeInEnabled: config.bargeIn.enabled,
            requireDirectAddress: config.conversation.requireDirectAddress,
            visionEnabled: config.vision.enabled,
            voiceIdentityLock: config.tts.voiceIdentityLock,
            approvalSnapshot: approvalSnapshot,
            registry: registry
        )
    }
}
