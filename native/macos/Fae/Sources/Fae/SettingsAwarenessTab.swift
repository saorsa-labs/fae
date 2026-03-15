import SwiftUI

/// Settings tab for configuring Proactive Awareness features.
struct SettingsAwarenessTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("awareness.enabled") private var awarenessEnabled: Bool = true
    @AppStorage("awareness.cameraEnabled") private var cameraEnabled: Bool = false
    @AppStorage("awareness.screenEnabled") private var screenEnabled: Bool = false
    @AppStorage("awareness.cameraIntervalSeconds") private var cameraInterval: Int = 30
    @AppStorage("awareness.screenIntervalSeconds") private var screenInterval: Int = 19
    @AppStorage("awareness.overnightWorkEnabled") private var overnightEnabled: Bool = false
    @AppStorage("awareness.enhancedBriefingEnabled") private var briefingEnabled: Bool = false
    @AppStorage("awareness.pauseOnBattery") private var pauseOnBattery: Bool = true
    @AppStorage("awareness.pauseOnThermalPressure") private var pauseOnThermal: Bool = true

    @State private var showingConsentAlert = false

    var body: some View {
        Form {
            // MARK: - Master Toggle
            Section {
                Toggle("Proactive Awareness", isOn: Binding(
                    get: { awarenessEnabled },
                    set: { newValue in
                        if newValue && !awarenessEnabled {
                            showingConsentAlert = true
                        } else if !newValue {
                            awarenessEnabled = false
                            patchConfig("awareness.enabled", false)
                        }
                    }
                ))
                .font(.headline)

                Text("Fae can watch for your presence, monitor screen activity, research overnight, and deliver enhanced morning briefings. Everything stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .alert("Enable Proactive Awareness?", isPresented: $showingConsentAlert) {
                Button("Enable") {
                    awarenessEnabled = true
                    patchConfig("awareness.consent_granted", true)
                    patchConfig("awareness.enabled", true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Fae will use the camera and screen capture to observe your presence and activity. All processing happens locally on this Mac — nothing leaves your device.")
            }

            if awarenessEnabled {
                // MARK: - Camera Monitoring
                Section("Camera Monitoring") {
                    Toggle("Presence detection & greetings", isOn: Binding(
                        get: { cameraEnabled },
                        set: { newValue in
                            cameraEnabled = newValue
                            patchConfig("awareness.camera_enabled", newValue)
                        }
                    ))

                    if cameraEnabled {
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
                }

                // MARK: - Screen Monitoring
                Section("Screen Monitoring") {
                    Toggle("Understand what you're working on", isOn: Binding(
                        get: { screenEnabled },
                        set: { newValue in
                            screenEnabled = newValue
                            patchConfig("awareness.screen_enabled", newValue)
                        }
                    ))

                    if screenEnabled {
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

                    Text("Screen observations are silent — Fae builds context but never interrupts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Intelligence Features
                Section("Intelligence") {
                    Toggle("Overnight research", isOn: Binding(
                        get: { overnightEnabled },
                        set: { newValue in
                            overnightEnabled = newValue
                            patchConfig("awareness.overnight_work", newValue)
                        }
                    ))
                    Text("Research topics you care about during quiet hours (22:00-06:00).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Enhanced morning briefing", isOn: Binding(
                        get: { briefingEnabled },
                        set: { newValue in
                            briefingEnabled = newValue
                            patchConfig("awareness.enhanced_briefing", newValue)
                        }
                    ))
                    Text("Calendar, mail, research findings, and reminders when you arrive in the morning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Resource Management
                Section("Resource Management") {
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

            Section {
                Button(awarenessEnabled ? "Re-run Awareness Setup" : "Set Up Proactive Awareness") {
                    commandSender?.sendCommand(name: "awareness.start_onboarding", payload: [:])
                }
                .buttonStyle(.borderedProminent)

                Text("Runs the guided setup flow with voice enrollment and awareness consent.")
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
