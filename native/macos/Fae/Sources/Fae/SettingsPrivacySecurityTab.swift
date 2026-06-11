import SwiftUI

struct SettingsPrivacySecurityTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case tools = "Tools"
        case voiceIdentity = "Voice Identity"
        case personality = "Personality"

        var id: String { rawValue }
    }

    var commandSender: HostCommandSender?
    var personalityEditor: PersonalityEditorController?
    var onToggleRescue: (() -> Void)?

    @State private var section: Section = .tools

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                switch section {
                case .tools:
                    SettingsToolsTab(commandSender: commandSender)
                case .voiceIdentity:
                    SettingsSpeakerTab(commandSender: commandSender)
                case .personality:
                    SettingsPersonalityTab(
                        personalityEditor: personalityEditor,
                        onToggleRescue: onToggleRescue
                    )
                }
            }
        }
    }
}
