import SwiftUI

struct SettingsSkillsChannelsWorkspace: View {
    enum Section: String, CaseIterable, Identifiable {
        case channels = "Channels"
        case skills = "Skills"

        var id: String { rawValue }
    }

    var commandSender: HostCommandSender?

    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @State private var section: Section = .skills

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
                case .channels:
                    SettingsChannelsTab(commandSender: commandSender)
                        .environmentObject(auxiliaryWindows)
                case .skills:
                    SettingsSkillsTab(commandSender: commandSender)
                }
            }
        }
    }
}
