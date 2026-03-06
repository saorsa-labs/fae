import AppKit
import SwiftUI

/// Skills management tab focused on personal skill CRUD while keeping built-in
/// Apple/system integrations available but visually de-emphasized.
struct SettingsSkillsTab: View {
    let commandSender: HostCommandSender?

    @State private var showingImport: Bool = false
    @State private var discoveredSkills: [SkillMetadata] = []
    @State private var editorDraft: EditableSkillDraft?
    @State private var deletingSkillName: String?
    @State private var showSharedSkills: Bool = true
    @State private var showAppleApps: Bool = false
    @State private var showSystemCapabilities: Bool = false

    private let coreAppleApps: [PermissionLink] = [
        .init(name: "Calendar", description: "View, create, and modify events", icon: "calendar", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
        .init(name: "Contacts", description: "Search and manage your address book", icon: "person.crop.circle", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"),
        .init(name: "Mail", description: "Read, search, and compose emails", icon: "envelope", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Notes", description: "Read, create, and append to notes", icon: "note.text", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Reminders", description: "Create and manage tasks and reminders", icon: "checklist", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"),
    ]

    private let extendedAppleApps: [PermissionLink] = [
        .init(name: "Messages", description: "Send and read iMessages and SMS", icon: "message", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Music", description: "Playback control and library search", icon: "music.note", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Safari", description: "Open URLs and manage bookmarks", icon: "safari", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Finder", description: "File management and folder navigation", icon: "folder.badge.gearshape", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Shortcuts", description: "Run and manage Shortcuts automations", icon: "square.on.square.badge.person.crop", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Photos", description: "Browse and search your photo library", icon: "photo.on.rectangle", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"),
        .init(name: "Maps", description: "Directions, local search, and places", icon: "map", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "FaceTime", description: "Initiate audio and video calls", icon: "video", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Pages", description: "Create and edit documents", icon: "doc.richtext", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Numbers", description: "Create and edit spreadsheets", icon: "tablecells", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Keynote", description: "Create and edit presentations", icon: "play.rectangle", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Books", description: "Browse and manage your book library", icon: "books.vertical", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        .init(name: "Podcasts", description: "Browse and control podcast playback", icon: "antenna.radiowaves.left.and.right", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
    ]

    private let systemCapabilities: [PermissionLink] = [
        .init(name: "Microphone", description: "Voice input for conversations", icon: "mic.fill", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
        .init(name: "Files", description: "Read and write documents on disk", icon: "folder", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
        .init(name: "Notifications", description: "Send proactive alerts and reminders", icon: "bell", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications"),
        .init(name: "Location", description: "Weather, local search, and directions", icon: "location", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"),
        .init(name: "Desktop Automation", description: "AppleScript, screenshots, and window management", icon: "gearshape.2", settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
    ]

    private var personalSkills: [SkillMetadata] {
        discoveredSkills.filter { $0.tier == .personal }
    }

    private var sharedSkills: [SkillMetadata] {
        discoveredSkills.filter { $0.tier != .personal }
    }

    var body: some View {
        Form {
            Section {
                Text("Personal skills are first-class here: create, edit, import, and remove them directly. Built-in and Apple integrations are still available, but tucked away so the screen stays focused.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Personal Skills") {
                HStack {
                    Button {
                        editorDraft = .new()
                    } label: {
                        Label("Create Skill", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingImport = true
                    } label: {
                        Label("Import Skill", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                }

                if personalSkills.isEmpty {
                    Text("No personal skills yet. Create one here or import an Agent Skill.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(personalSkills, id: \.name) { skill in
                        skillMetadataRow(skill, allowEditing: true)
                    }
                }
            }

            Section("Built-in & Shared Skills") {
                DisclosureGroup(isExpanded: $showSharedSkills) {
                    if sharedSkills.isEmpty {
                        Text("No shared or bundled skills discovered.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(sharedSkills, id: \.name) { skill in
                            skillMetadataRow(skill, allowEditing: false)
                        }
                    }
                } label: {
                    Text("\(sharedSkills.count) available")
                }
            }

            Section("Apple & System Access") {
                DisclosureGroup(isExpanded: $showAppleApps) {
                    Text("Core Apple apps use dedicated tools. Extended apps use Desktop Automation.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(coreAppleApps + extendedAppleApps) { item in
                        permissionRow(item)
                    }
                } label: {
                    Text("Apple integrations")
                }

                DisclosureGroup(isExpanded: $showSystemCapabilities) {
                    Text("Open the relevant privacy panes only when you need them.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(systemCapabilities) { item in
                        permissionRow(item)
                    }
                } label: {
                    Text("System capabilities")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingImport) {
            SkillImportView(commandSender: commandSender)
                .onDisappear { refreshSkills() }
        }
        .sheet(item: $editorDraft) { draft in
            SkillEditorSheet(draft: draft) { savedDraft in
                saveSkill(savedDraft)
            }
        }
        .confirmationDialog(
            "Remove skill?",
            isPresented: Binding(
                get: { deletingSkillName != nil },
                set: { if !$0 { deletingSkillName = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Skill", role: .destructive) {
                if let deletingSkillName {
                    removeSkill(named: deletingSkillName)
                }
                deletingSkillName = nil
            }
            Button("Cancel", role: .cancel) {
                deletingSkillName = nil
            }
        } message: {
            Text("This removes the personal skill from your local Fae skills directory.")
        }
        .onAppear {
            refreshSkills()
        }
    }

    private func skillMetadataRow(_ skill: SkillMetadata, allowEditing: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skill.type == .executable ? "chevron.left.forwardslash.chevron.right" : "doc.text")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(skill.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 4) {
                tierBadge(skill.tier)
                typeBadge(skill.type)
                if !skill.isEnabled {
                    Text("Disabled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            if allowEditing {
                Button {
                    editorDraft = EditableSkillDraft.loadPersonalSkill(named: skill.name)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    deletingSkillName = skill.name
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func permissionRow(_ item: PermissionLink) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(item.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings") {
                openPrivacySettings(item.settingsURL)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func openPrivacySettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func tierBadge(_ tier: SkillTier) -> some View {
        let (label, color): (String, Color) = switch tier {
        case .builtin: ("Built-in", .blue)
        case .personal: ("Personal", .green)
        case .community: ("Community", .orange)
        }
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func typeBadge(_ type: SkillType) -> some View {
        let (label, color): (String, Color) = switch type {
        case .instruction: ("Instruction", .purple)
        case .executable: ("Executable", .teal)
        }
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func refreshSkills() {
        Task {
            let manager = SkillManager()
            let all = await manager.discoverSkills()
            await MainActor.run {
                discoveredSkills = all.sorted { $0.name < $1.name }
            }
        }
    }

    private func saveSkill(_ draft: EditableSkillDraft) {
        Task {
            let manager = SkillManager()
            do {
                switch draft.mode {
                case .create:
                    _ = try await manager.createSkill(
                        name: draft.trimmedName,
                        description: draft.trimmedDescription,
                        body: draft.trimmedBody
                    )
                case .edit(let existingName):
                    _ = try await manager.updateSkill(
                        name: existingName,
                        description: draft.trimmedDescription,
                        body: draft.trimmedBody
                    )
                }
                await MainActor.run {
                    refreshSkills()
                    commandSender?.sendCommand(name: "skills.reload", payload: [:])
                }
            } catch {
                NSLog("SettingsSkillsTab: failed to save skill %@", error.localizedDescription)
            }
        }
    }

    private func removeSkill(named name: String) {
        Task {
            do {
                try await SkillManager().deleteSkill(name: name)
                await MainActor.run {
                    refreshSkills()
                    commandSender?.sendCommand(name: "skills.reload", payload: [:])
                }
            } catch {
                NSLog("SettingsSkillsTab: failed to remove skill %@", error.localizedDescription)
            }
        }
    }
}

private struct PermissionLink: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let settingsURL: String
}
