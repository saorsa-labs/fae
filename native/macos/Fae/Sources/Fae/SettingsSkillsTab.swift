import AppKit
import SwiftUI

/// Skills management tab: directory-based skills with type/tier badges,
/// Apple app integrations, and system capabilities.
///
/// Apple apps are split into two tiers:
/// - **Core Apps** (5): have dedicated LLM tools with structured data access
/// - **Extended Apps** (13): accessible via AppleScript through Desktop Automation
///
/// System capabilities (Microphone, Files, Notifications, Location, Desktop Automation)
/// are shown in a separate section. Each row links to the relevant macOS Privacy pane.
struct SettingsSkillsTab: View {
    let commandSender: HostCommandSender?

    @State private var showingImport: Bool = false
    @State private var discoveredSkills: [SkillMetadata] = []

    var body: some View {
        Form {
            // MARK: - Header

            Section {
                Text("Fae can work with 18 Apple apps and 5 system capabilities. Core apps have dedicated tools; extended apps work through Desktop Automation. Grant access in System Settings when prompted, or open the relevant pane below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Installed Skills

            Section("Skills") {
                Text("Directory-based skills following the Agent Skills standard. Each skill has a SKILL.md with instructions and optional Python scripts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    showingImport = true
                } label: {
                    Label("Import Skill from URL", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)

                if discoveredSkills.isEmpty {
                    Text("No skills installed")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(discoveredSkills, id: \.name) { skill in
                        skillMetadataRow(skill)
                    }
                }
            }

            // MARK: - Core Apple Apps (dedicated tools)

            Section("Core Apple Apps") {
                Text("These apps have dedicated tools with structured data access.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                skillRow(
                    name: "Calendar",
                    description: "View, create, and modify events",
                    icon: "calendar",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                )
                skillRow(
                    name: "Contacts",
                    description: "Search and manage your address book",
                    icon: "person.crop.circle",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
                )
                skillRow(
                    name: "Mail",
                    description: "Read, search, and compose emails",
                    icon: "envelope",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Notes",
                    description: "Read, create, and append to notes",
                    icon: "note.text",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Reminders",
                    description: "Create and manage tasks and reminders",
                    icon: "checklist",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
                )
            }

            // MARK: - Extended Apple Apps (via AppleScript)

            Section("Extended Apple Apps") {
                Text("These apps work via AppleScript and require Desktop Automation permission.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                skillRow(
                    name: "Messages",
                    description: "Send and read iMessages and SMS",
                    icon: "message",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Music",
                    description: "Playback control and library search",
                    icon: "music.note",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Safari",
                    description: "Open URLs and manage bookmarks",
                    icon: "safari",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Finder",
                    description: "File management and folder navigation",
                    icon: "folder.badge.gearshape",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Shortcuts",
                    description: "Run and manage Shortcuts automations",
                    icon: "square.on.square.badge.person.crop",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Photos",
                    description: "Browse and search your photo library",
                    icon: "photo.on.rectangle",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
                )
                skillRow(
                    name: "Maps",
                    description: "Directions, local search, and places",
                    icon: "map",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "FaceTime",
                    description: "Initiate audio and video calls",
                    icon: "video",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Pages",
                    description: "Create and edit documents",
                    icon: "doc.richtext",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Numbers",
                    description: "Create and edit spreadsheets",
                    icon: "tablecells",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Keynote",
                    description: "Create and edit presentations",
                    icon: "play.rectangle",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Books",
                    description: "Browse and manage your book library",
                    icon: "books.vertical",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
                skillRow(
                    name: "Podcasts",
                    description: "Browse and control podcast playback",
                    icon: "antenna.radiowaves.left.and.right",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            }

            // MARK: - System Capabilities

            Section("System Capabilities") {
                Text("System-level permissions for voice input, file access, and automation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                skillRow(
                    name: "Microphone",
                    description: "Voice input for conversations",
                    icon: "mic.fill",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                skillRow(
                    name: "Files",
                    description: "Read and write documents on disk",
                    icon: "folder",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                )
                skillRow(
                    name: "Notifications",
                    description: "Send proactive alerts and reminders",
                    icon: "bell",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications"
                )
                skillRow(
                    name: "Location",
                    description: "Weather, local search, and directions",
                    icon: "location",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
                )
                skillRow(
                    name: "Desktop Automation",
                    description: "AppleScript, screenshots, window management",
                    icon: "gearshape.2",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingImport) {
            SkillImportView(commandSender: commandSender)
                .onDisappear { refreshSkills() }
        }
        .onAppear {
            refreshSkills()
        }
    }

    // MARK: - Skill Metadata Row (v2 directory-based)

    private func skillMetadataRow(_ skill: SkillMetadata) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skill.type == .executable
                  ? "chevron.left.forwardslash.chevron.right"
                  : "doc.text")
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
            }

            if skill.tier == .personal {
                Button(role: .destructive) {
                    removeSkill(named: skill.name)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Apple App Row

    private func skillRow(
        name: String,
        description: String,
        icon: String,
        settingsURL: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings") {
                openPrivacySettings(settingsURL)
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

    // MARK: - Badges

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

    // MARK: - Skills Management

    private func refreshSkills() {
        let fm = FileManager.default
        var all: [SkillMetadata] = []

        // Built-in skills from app bundle.
        if let builtinDir = Bundle.main.url(forResource: "Skills", withExtension: nil) {
            all.append(contentsOf: scanSkillDirectory(builtinDir, tier: .builtin, fm: fm))
        }

        // Personal skills.
        all.append(contentsOf: scanSkillDirectory(SkillManager.skillsDirectory, tier: .personal, fm: fm))

        discoveredSkills = all.sorted { $0.name < $1.name }
    }

    private func scanSkillDirectory(_ dir: URL, tier: SkillTier, fm: FileManager) -> [SkillMetadata] {
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var results: [SkillMetadata] = []
        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let skillMd = url.appendingPathComponent("SKILL.md")
            if let metadata = SkillParser.parse(skillURL: skillMd, tier: tier) {
                results.append(metadata)
            }
        }
        return results
    }

    private func removeSkill(named name: String) {
        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: skillDir)
        refreshSkills()
        commandSender?.sendCommand(name: "skills.reload", payload: [:])
    }
}
