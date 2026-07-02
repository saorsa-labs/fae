import SwiftUI

/// Settings tab for personality configuration — soul, custom instructions, rescue mode.
struct SettingsPersonalityTab: View {
    var personalityEditor: PersonalityEditorController?
    var onToggleRescue: (() -> Void)?

    @EnvironmentObject private var rescueMode: RescueMode

    @State private var selectedCommit: String?
    @State private var isLoadingSnapshots = false
    @State private var showRestoreConfirm = false
    @State private var restoreOutcome: RestoreOutcome?

    private enum RestoreOutcome: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            // MARK: - Soul Contract

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Soul Contract")
                            .font(.headline)
                        Text(soulStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showSoulEditor()
                    }
                    Button("Reset") {
                        try? SoulManager.resetToDefault()
                    }
                }
            } header: {
                Text("Soul")
            }

            // MARK: - Directive

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Directive")
                            .font(.headline)
                        Text(directiveStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showInstructionsEditor()
                    }
                    Button("Clear") {
                        clearDirective()
                    }
                    .disabled(SelfConfigTool.readInstructions().isEmpty)
                }
            } header: {
                Text("Directive")
            } footer: {
                Text("Critical instructions Fae follows in every conversation. Usually empty — only add something here if it's important enough to override normal behavior.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Heartbeat")
                            .font(.headline)
                        Text(heartbeatStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showHeartbeatEditor()
                    }
                    Button("Reset") {
                        try? HeartbeatManager.resetToDefault()
                    }
                }
            } header: {
                Text("Heartbeat")
            } footer: {
                Text("Rules for when Fae speaks up on her own and how she asks for permission before taking actions.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // MARK: - Rescue Mode

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rescue Mode")
                            .font(.headline)
                        Text(rescueMode.isActive
                             ? "Active — running with default settings"
                             : "Inactive — running normally")
                            .font(.caption)
                            .foregroundColor(rescueMode.isActive ? .orange : .secondary)
                    }
                    Spacer()
                    Button(rescueMode.isActive ? "Exit Rescue Mode" : "Enter Rescue Mode") {
                        onToggleRescue?()
                    }
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("Rescue Mode starts Fae with default settings, bypassing custom soul and instructions. Your data is preserved.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // MARK: - Restore from Vault (rescue mode only)

            if rescueMode.isActive {
                restoreFromVaultSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 300)
        .task(id: rescueMode.isActive) {
            if rescueMode.isActive {
                await refreshSnapshots()
            }
        }
        .confirmationDialog(
            "Restore from this backup?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore Backup", role: .destructive) {
                Task { await performRestore() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - Restore from Vault

    @ViewBuilder
    private var restoreFromVaultSection: some View {
        Section {
            if rescueMode.availableSnapshots.isEmpty {
                HStack {
                    Text(isLoadingSnapshots ? "Loading backups\u{2026}" : "No backups found in the vault.")
                        .font(.caption)
                        .foregroundColor(FaeDesign.textMuted)
                    Spacer()
                    Button("Reload") {
                        Task { await refreshSnapshots() }
                    }
                    .disabled(isLoadingSnapshots)
                }
            } else {
                Picker("Backup", selection: $selectedCommit) {
                    ForEach(rescueMode.availableSnapshots, id: \.commitHash) { snapshot in
                        Text(snapshotLabel(snapshot)).tag(Optional(snapshot.commitHash))
                    }
                }

                HStack {
                    Spacer()
                    Button("Restore Selected\u{2026}") {
                        showRestoreConfirm = true
                    }
                    .disabled(selectedCommit == nil || rescueMode.isRestoring)
                }

                if rescueMode.isRestoring {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Restoring\u{2026}")
                            .font(.caption)
                            .foregroundColor(FaeDesign.textSecondary)
                    }
                }
            }

            if let outcome = restoreOutcome {
                restoreStatusRow(outcome)
            }
        } header: {
            Text("Restore from Vault")
        } footer: {
            Text("Replaces Fae's soul, memory, settings, and skills with a saved backup. Fae quits afterward so the restored data loads cleanly. This cannot be undone.")
                .font(.caption2)
                .foregroundColor(FaeDesign.textMuted)
        }
    }

    @ViewBuilder
    private func restoreStatusRow(_ outcome: RestoreOutcome) -> some View {
        switch outcome {
        case .success:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(FaeDesign.statusSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore complete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(FaeDesign.textPrimary)
                    Text("Quit Fae to load the restored data.")
                        .font(.caption)
                        .foregroundColor(FaeDesign.textSecondary)
                }
                Spacer()
                Button("Quit Fae") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        case .failure(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(FaeDesign.statusError)
                Text(message)
                    .font(.caption)
                    .foregroundColor(FaeDesign.rowanBerryText)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func refreshSnapshots() async {
        isLoadingSnapshots = true
        await rescueMode.loadSnapshots()
        if let selected = selectedCommit,
           !rescueMode.availableSnapshots.contains(where: { $0.commitHash == selected }) {
            selectedCommit = nil
        }
        isLoadingSnapshots = false
    }

    private func performRestore() async {
        guard let commit = selectedCommit else { return }
        let succeeded = await rescueMode.restore(commit: commit)
        restoreOutcome = succeeded
            ? .success
            : .failure("Restore failed. Your current data is unchanged.")
    }

    private func snapshotLabel(_ snapshot: GitVaultManager.VaultSnapshot) -> String {
        let shortHash = String(snapshot.commitHash.prefix(7))
        let date = Self.snapshotDateFormatter.string(from: snapshot.date)
        return "\(date)  ·  \(snapshot.message)  ·  \(shortHash)"
    }

    private var confirmMessage: String {
        guard let commit = selectedCommit,
              let snapshot = rescueMode.availableSnapshots.first(where: { $0.commitHash == commit })
        else {
            return "This replaces Fae's current data with the selected backup. This cannot be undone."
        }
        let date = Self.snapshotDateFormatter.string(from: snapshot.date)
        return "Fae's soul, memory, settings, and skills will be replaced with the backup from \(date). This cannot be undone."
    }

    private static let snapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    // MARK: - Status Helpers

    private var soulStatusLine: String {
        let lines = SoulManager.lineCount
        let status = SoulManager.isModified ? "modified" : "default"
        return "\(lines) lines, \(status)"
    }

    private var directiveStatusLine: String {
        let text = SelfConfigTool.readInstructions()
        if text.isEmpty {
            return "Empty (no active directives)"
        }
        return "\(text.count) / 4000 characters"
    }

    private var heartbeatStatusLine: String {
        let lines = HeartbeatManager.lineCount
        let status = HeartbeatManager.isModified ? "modified" : "default"
        return "\(lines) lines, \(status)"
    }

    private func clearDirective() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let url = appSupport.appendingPathComponent("fae/directive.md")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}
