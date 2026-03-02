import SwiftUI

/// Developer settings tab: orb controls, raw command input.
/// Hidden unless activated via Option-click or debug flag.
struct SettingsDeveloperTab: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @State private var commandText: String = ""

    @AppStorage("fae.feature.world_class_settings") private var worldClassSettingsEnabled: Bool = true
    @AppStorage("fae.feature.channel_setup_forms") private var channelSetupFormsEnabled: Bool = true

    @State private var dashboard = SecurityDashboardSnapshot.empty
    @State private var dashboardLoading = false
    @State private var dashboardError: String?

    var body: some View {
        Form {
            Section("Orb Controls") {
                Picker("Mode", selection: $orbState.mode) {
                    ForEach(OrbMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Palette", selection: $orbState.palette) {
                    ForEach(OrbPalette.allCases) { palette in
                        Text(palette.label).tag(palette)
                    }
                }

                Picker("Feeling", selection: $orbState.feeling) {
                    ForEach(OrbFeeling.allCases) { feeling in
                        Text(feeling.label).tag(feeling)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Commands") {
                HStack(spacing: 8) {
                    TextField("Enter command...", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        applyCommand(commandText)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Last: \(handoff.lastCommandText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Rollout Flags (Local)") {
                Toggle("World-class settings IA", isOn: $worldClassSettingsEnabled)
                Toggle("Channel setup guided forms", isOn: $channelSetupFormsEnabled)

                HStack {
                    Text("Form opens")
                    Spacer()
                    Text("\(UserDefaults.standard.integer(forKey: "channel_setup.request_form.opened"))")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)

                HStack {
                    Text("Form submissions")
                    Spacer()
                    Text("\(UserDefaults.standard.integer(forKey: "channel_setup.request_form.submitted"))")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }

            Section("Security Dashboard (Local/Dev)") {
                if dashboardLoading {
                    ProgressView("Loading metrics…")
                }

                if let dashboardError {
                    Text(dashboardError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Label("Calls: \(dashboard.totalCalls)", systemImage: "hammer")
                    Spacer()
                    Label("Failures: \(dashboard.failures)", systemImage: "exclamationmark.triangle")
                }
                .font(.footnote)

                HStack {
                    Label("Allow: \(dashboard.allowCount)", systemImage: "checkmark.circle")
                    Spacer()
                    Label("Confirm: \(dashboard.confirmCount)", systemImage: "questionmark.circle")
                    Spacer()
                    Label("Deny: \(dashboard.denyCount)", systemImage: "xmark.circle")
                }
                .font(.footnote)

                if !dashboard.categoryCalls.isEmpty {
                    Text("Action categories")
                        .font(.footnote.weight(.semibold))
                    ForEach(dashboard.categoryCalls.sorted(by: { $0.key < $1.key }), id: \.key) {
                        category, count in
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }

                if !dashboard.topReasons.isEmpty {
                    Text("Top reason codes")
                        .font(.footnote.weight(.semibold))
                    ForEach(dashboard.topReasons, id: \.reason) { item in
                        HStack {
                            Text(item.reason)
                            Spacer()
                            Text("\(item.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }

                Button("Refresh Dashboard") {
                    Task { await refreshDashboard() }
                }
            }
        }
        .task {
            await refreshDashboard()
        }
        .formStyle(.grouped)
    }

    private func applyCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let palette = OrbPalette.commandOverride(in: trimmed) {
            orbState.palette = palette
            handoff.note(commandText: "Orb palette set to \(palette.label)")
            commandText = ""
            return
        }

        if let mode = OrbMode.commandOverride(in: trimmed) {
            orbState.mode = mode
            handoff.note(commandText: "Orb mode set to \(mode.label)")
            commandText = ""
            return
        }

        if let feeling = OrbFeeling.commandOverride(in: trimmed) {
            orbState.feeling = feeling
            handoff.note(commandText: "Orb feeling set to \(feeling.label)")
            commandText = ""
            return
        }

        let result = handoff.execute(commandText: raw)
        switch result {
        case .move(let target):
            orbState.mode = target == .watch ? .speaking : .listening
        case .goHome:
            orbState.mode = .idle
        case .unsupported:
            orbState.mode = .thinking
        }
        commandText = ""
    }

    private func refreshDashboard() async {
        dashboardLoading = true
        dashboardError = nil

        do {
            let path = NSHomeDirectory() + "/Library/Application Support/fae/tool_analytics.db"
            let analytics = try ToolAnalytics(path: path)
            let summary = await analytics.summary()

            let totalCalls = summary.reduce(0) { $0 + $1.totalCalls }
            let failures = summary.reduce(0) { $0 + $1.failureCount }

            var categoryCalls: [String: Int] = [:]
            for row in summary {
                categoryCalls[category(for: row.toolName), default: 0] += row.totalCalls
            }

            let securityStats = loadSecurityEventStats()
            dashboard = SecurityDashboardSnapshot(
                totalCalls: totalCalls,
                failures: failures,
                allowCount: securityStats.allowCount,
                confirmCount: securityStats.confirmCount,
                denyCount: securityStats.denyCount,
                categoryCalls: categoryCalls,
                topReasons: securityStats.topReasons
            )
        } catch {
            dashboardError = "Failed to load dashboard: \(error.localizedDescription)"
        }

        dashboardLoading = false
    }

    private func category(for tool: String) -> String {
        switch tool {
        case "read", "write", "edit": return "Files"
        case "bash": return "Execution"
        case "web_search", "fetch_url": return "Network"
        case "run_skill", "manage_skill", "activate_skill": return "Skills"
        case "calendar", "reminders", "contacts", "mail", "notes": return "Apple"
        case "scheduler_list", "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger":
            return "Scheduler"
        default:
            return "Other"
        }
    }

    private func loadSecurityEventStats() -> SecurityEventStats {
        let path = NSHomeDirectory() + "/Library/Application Support/fae/security-events.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else {
            return .empty
        }

        var allow = 0
        var confirm = 0
        var deny = 0
        var reasonCounts: [String: Int] = [:]

        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n")
        for line in lines.suffix(2000) {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(SecurityDashboardEvent.self, from: data)
            else {
                continue
            }

            switch event.decision {
            case "allow", "allow_with_transform": allow += 1
            case "confirm": confirm += 1
            case "deny": deny += 1
            default: break
            }

            if let reason = event.reasonCode, !reason.isEmpty {
                reasonCounts[reason, default: 0] += 1
            }
        }

        let topReasons = reasonCounts
            .map { SecurityDashboardSnapshot.ReasonCount(reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(5)

        return SecurityEventStats(
            allowCount: allow,
            confirmCount: confirm,
            denyCount: deny,
            topReasons: Array(topReasons)
        )
    }
}

private struct SecurityDashboardEvent: Decodable {
    let decision: String?
    let reasonCode: String?
}

private struct SecurityEventStats {
    let allowCount: Int
    let confirmCount: Int
    let denyCount: Int
    let topReasons: [SecurityDashboardSnapshot.ReasonCount]

    static let empty = SecurityEventStats(
        allowCount: 0,
        confirmCount: 0,
        denyCount: 0,
        topReasons: []
    )
}

private struct SecurityDashboardSnapshot {
    struct ReasonCount {
        let reason: String
        let count: Int
    }

    let totalCalls: Int
    let failures: Int
    let allowCount: Int
    let confirmCount: Int
    let denyCount: Int
    let categoryCalls: [String: Int]
    let topReasons: [ReasonCount]

    static let empty = SecurityDashboardSnapshot(
        totalCalls: 0,
        failures: 0,
        allowCount: 0,
        confirmCount: 0,
        denyCount: 0,
        categoryCalls: [:],
        topReasons: []
    )
}
