import AppKit
import SwiftUI

/// Skills management tab: custom skill import, installed custom skills,
/// all 18 Apple apps Fae can interact with, plus system capabilities.
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
    @State private var installedSkills: [String] = []

    var body: some View {
        Form {
            // MARK: - Header

            Section {
                Text("Fae can work with 18 Apple apps and 5 system capabilities. Core apps have dedicated tools; extended apps work through Desktop Automation. Grant access in System Settings when prompted, or open the relevant pane below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Custom Skills

            Section("Custom Skills") {
                Text("Import skills from a URL or manage your installed custom skills. Changes take effect on next app restart.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    showingImport = true
                } label: {
                    Label("Import Skill from URL", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)

                if !installedSkills.isEmpty {
                    ForEach(installedSkills, id: \.self) { skill in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .center)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                Text("Custom skill")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                removeSkill(named: skill)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
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
                .onDisappear { refreshInstalledSkills() }
        }
        .onAppear { refreshInstalledSkills() }
    }

    // MARK: - Skill Row

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

    // MARK: - Custom Skills Management

    private var skillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae/skills")
    }

    private func refreshInstalledSkills() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            installedSkills = []
            return
        }
        installedSkills = contents
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func removeSkill(named name: String) {
        let filePath = skillsDirectory.appendingPathComponent("\(name).md")
        try? FileManager.default.removeItem(at: filePath)
        refreshInstalledSkills()
        commandSender?.sendCommand(name: "skills.reload", payload: [:])
    }
}
