import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @EnvironmentObject private var onboarding: OnboardingController

    /// Command sender for issuing backend commands (e.g. config.patch).
    /// Injected via the environment from FaeNativeApp.
    var commandSender: HostCommandSender?

    /// Sparkle auto-update controller for "Check for Updates" UI.
    var sparkleUpdater: SparkleUpdaterController?

    /// Hold Option while opening Settings to reveal the Developer tab.
    @State private var showDeveloper: Bool = false

    var body: some View {
        TabView {
            SettingsGeneralTab()
                .environmentObject(auxiliaryWindows)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            SettingsModelsTab()
                .environmentObject(pipelineAux)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            SettingsToolsTab(commandSender: commandSender)
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }

            SettingsChannelsTab(commandSender: commandSender)
                .tabItem {
                    Label("Channels", systemImage: "bubble.left.and.bubble.right")
                }

            SettingsSkillsTab(commandSender: commandSender)
                .tabItem {
                    Label("Skills", systemImage: "sparkles")
                }

            SettingsAboutTab(commandSender: commandSender, sparkleUpdater: sparkleUpdater)
                .environmentObject(handoff)
                .environmentObject(onboarding)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }

            if showDeveloper {
                SettingsDeveloperTab()
                    .environmentObject(orbState)
                    .environmentObject(handoff)
                    .tabItem {
                        Label("Developer", systemImage: "hammer")
                    }
            }
        }
        .frame(minWidth: 500, minHeight: 420)
        .onAppear {
            showDeveloper = NSEvent.modifierFlags.contains(.option)
        }
    }
}
