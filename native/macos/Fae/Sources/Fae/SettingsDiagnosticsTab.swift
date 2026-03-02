import SwiftUI

struct SettingsDiagnosticsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case about = "About"
        case developer = "Developer"

        var id: String { rawValue }
    }

    var commandSender: HostCommandSender?
    var showDeveloper: Bool

    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var onboarding: OnboardingController

    @State private var section: Section = .about

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showDeveloper {
                Picker("Section", selection: $section) {
                    Text(Section.about.rawValue).tag(Section.about)
                    Text(Section.developer.rawValue).tag(Section.developer)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            Group {
                if showDeveloper, section == .developer {
                    SettingsDeveloperTab()
                        .environmentObject(orbState)
                        .environmentObject(handoff)
                } else {
                    SettingsAboutTab(commandSender: commandSender)
                        .environmentObject(handoff)
                        .environmentObject(onboarding)
                }
            }
        }
    }
}
