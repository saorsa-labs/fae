import SwiftUI

struct SettingsOverviewTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"

        var id: String { rawValue }
    }

    var commandSender: HostCommandSender?

    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @State private var section: Section = .overview

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
                case .overview:
                    SettingsGeneralTab()
                        .environmentObject(auxiliaryWindows)
                case .models:
                    SettingsModelsTab(commandSender: commandSender)
                }
            }
        }
    }
}
