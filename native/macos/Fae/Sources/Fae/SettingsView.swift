import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var conversation: ConversationRuntimeController

    /// Command sender for issuing backend commands (e.g. config.patch).
    /// Injected via the environment from FaeApp.
    var commandSender: HostCommandSender?

    /// Personality editor controller for opening soul/instructions editors.
    var personalityEditor: PersonalityEditorController?

    /// Callback to toggle rescue mode from the Personality tab.
    var onToggleRescue: (() -> Void)?

    /// Hold Option while opening Settings to reveal the Developer tab.
    @State private var showDeveloper: Bool = false

    @AppStorage("fae.feature.world_class_settings")
    private var worldClassSettingsEnabled: Bool = true

    var body: some View {
        TabView {
            if worldClassSettingsEnabled {
                SettingsOverviewTab(commandSender: commandSender)
                    .environmentObject(auxiliaryWindows)
                    .tabItem {
                        Label("Overview", systemImage: "rectangle.grid.2x2")
                    }

                SettingsModelsPerformanceTab(commandSender: commandSender)
                    .tabItem {
                        Label("Models & Performance", systemImage: "cpu")
                    }

                SettingsSkillsTab(commandSender: commandSender)
                    .tabItem {
                        Label("Skills", systemImage: "sparkles")
                    }

                SettingsChannelsTab(commandSender: commandSender)
                    .tabItem {
                        Label("Channels", systemImage: "bubble.left.and.bubble.right")
                    }

                SettingsPrivacySecurityTab(
                    commandSender: commandSender,
                    personalityEditor: personalityEditor,
                    onToggleRescue: onToggleRescue
                )
                .tabItem {
                    Label("Privacy & Security", systemImage: "lock.shield")
                }

                SettingsAwarenessTab(commandSender: commandSender)
                    .tabItem {
                        Label("Awareness", systemImage: "eye")
                    }

                SettingsTrainingTab(commandSender: commandSender)
                    .tabItem {
                        Label("Learning", systemImage: "graduationcap")
                    }

                SettingsMemoryTab(commandSender: commandSender)
                    .tabItem {
                        Label("Memory", systemImage: "brain")
                    }

                SettingsDiagnosticsTab(
                    commandSender: commandSender,
                    showDeveloper: showDeveloper
                )
                .environmentObject(orbState)
                .environmentObject(handoff)
                .environmentObject(onboarding)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } else {
                SettingsGeneralTab()
                    .environmentObject(auxiliaryWindows)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }

                SettingsModelsTab(commandSender: commandSender)
                    .tabItem {
                        Label("Models", systemImage: "cpu")
                    }

                // Voice Identity tab hidden (teardown Phase A) — the tab file
                // itself goes in the Phase B deletion pass.

                SettingsToolsTab(commandSender: commandSender)
                    .tabItem {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }

                SettingsPersonalityTab(
                    personalityEditor: personalityEditor,
                    onToggleRescue: onToggleRescue
                )
                .tabItem {
                    Label("Personality", systemImage: "heart")
                }

                SettingsAwarenessTab(commandSender: commandSender)
                    .tabItem {
                        Label("Awareness", systemImage: "eye")
                    }

                SettingsTrainingTab(commandSender: commandSender)
                    .tabItem {
                        Label("Learning", systemImage: "graduationcap")
                    }

                SettingsSchedulesTab(commandSender: commandSender)
                    .tabItem {
                        Label("Schedules", systemImage: "calendar.badge.clock")
                    }

                SettingsChannelsTab(commandSender: commandSender)
                    .tabItem {
                        Label("Channels", systemImage: "bubble.left.and.bubble.right")
                    }

                SettingsSkillsTab(commandSender: commandSender)
                    .tabItem {
                        Label("Skills", systemImage: "sparkles")
                    }

                SettingsAboutTab(commandSender: commandSender)
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
        }
        .frame(minWidth: 920, minHeight: 680)
        .onAppear {
            showDeveloper = NSEvent.modifierFlags.contains(.option)
        }
    }
}
