import SwiftUI

/// Settings tab for Proactive Awareness — informational showcase with intensity controls.
///
/// All awareness features are always-on (proactive-by-default philosophy).
/// This tab educates the user about what Fae does and why, and provides
/// intensity controls (intervals) and power management toggles.
struct SettingsAwarenessTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("awareness.cameraIntervalSeconds") private var cameraInterval: Int = 60
    @AppStorage("awareness.screenIntervalSeconds") private var screenInterval: Int = 30
    @AppStorage("awareness.pauseOnBattery") private var pauseOnBattery: Bool = true
    @AppStorage("awareness.pauseOnThermalPressure") private var pauseOnThermal: Bool = true

    var body: some View {
        Form {
            // MARK: - Overview
            Section {
                Text("Fae is always watching out for you — observing your presence, understanding what you're working on, researching overnight, and delivering morning briefings. Everything stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Presence Detection
            Section("Presence Detection") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Camera presence & greetings")
                            .font(.body)
                        Text("Fae knows when you sit down, greets you, and notices when you leave. She can read your mood and offer support when you need it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "eye")
                        .foregroundStyle(.blue)
                }

                HStack {
                    Text("Check interval")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { cameraInterval },
                        set: { newValue in
                            cameraInterval = newValue
                            patchConfig("awareness.camera_interval_seconds", newValue)
                        }
                    )) {
                        Text("10s").tag(10)
                        Text("30s").tag(30)
                        Text("60s").tag(60)
                        Text("120s").tag(120)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }

            // MARK: - Screen Awareness
            Section("Screen Awareness") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Understand what you're working on")
                            .font(.body)
                        Text("Fae silently builds context from your screen — she never interrupts, but she's ready to help with whatever you're doing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "display")
                        .foregroundStyle(.blue)
                }

                HStack {
                    Text("Check interval")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { screenInterval },
                        set: { newValue in
                            screenInterval = newValue
                            patchConfig("awareness.screen_interval_seconds", newValue)
                        }
                    )) {
                        Text("10s").tag(10)
                        Text("19s").tag(19)
                        Text("30s").tag(30)
                        Text("60s").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }

            // MARK: - Intelligence
            Section("Intelligence") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overnight research")
                            .font(.body)
                        Text("While you sleep (22:00-06:00), Fae researches topics you care about so she has fresh insights in the morning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "moon.stars")
                        .foregroundStyle(.indigo)
                }

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enhanced morning briefing")
                            .font(.body)
                        Text("When you arrive, Fae delivers your calendar, important mail, overnight research findings, and reminders — everything you need to start the day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sunrise")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: - Power Management
            Section("Power Management") {
                Toggle("Pause on battery", isOn: Binding(
                    get: { pauseOnBattery },
                    set: { newValue in
                        pauseOnBattery = newValue
                        patchConfig("awareness.pause_on_battery", newValue)
                    }
                ))

                Toggle("Pause when Mac is hot", isOn: Binding(
                    get: { pauseOnThermal },
                    set: { newValue in
                        pauseOnThermal = newValue
                        patchConfig("awareness.pause_on_thermal_pressure", newValue)
                    }
                ))

                Text("Fae pauses background observations to save battery and prevent your Mac from overheating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func patchConfig(_ key: String, _ value: Any) {
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": key, "value": value]
        )
    }
}
