import AppKit
import AVKit
import SwiftUI

/// General settings tab: audio input/output and window behavior.
struct SettingsGeneralTab: View {
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @EnvironmentObject private var faeCore: FaeCore
    @StateObject private var audio = AudioDeviceController()
    @State private var pushToTalkOnly = false
    @State private var pttHotkeySelection = -1
    @State private var pttControlsHydrated = false

    /// Hold-to-talk key options (macOS virtual key codes). -1 = default
    /// (Right Option), stored as nil in config.
    private static let pttHotkeyOptions: [(label: String, keyCode: Int)] = [
        ("Right Option (default)", -1),
        ("Right Command", 54),
        ("F5", 96),
        ("F6", 97),
    ]

    var body: some View {
        Form {
            Section("Audio Input") {
                HStack {
                    Text("Microphone")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Button("Refresh") {
                        audio.refreshMicrophoneAccessAndDevices()
                    }
                    .buttonStyle(.bordered)
                }
                if audio.microphoneAccessGranted {
                    Picker("Microphone", selection: $audio.selectedInputID) {
                        ForEach(audio.inputDevices) { input in
                            Text(input.name).tag(input.id)
                        }
                    }
                    .labelsHidden()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Microphone access required for listening mode.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open Privacy Settings") {
                            openMicrophonePrivacySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                HStack {
                    Text("Selected:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(audio.selectedInputName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Audio Output") {
                HStack {
                    Text("Output Route")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    AudioRoutePicker()
                        .frame(width: 30, height: 24)
                }
                Text("Route output to nearby Apple devices (iPhone, Watch, AirPods, HomePod).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Push to Talk") {
                Toggle("Push-to-talk only", isOn: $pushToTalkOnly)
                    .onChange(of: pushToTalkOnly) { _, newValue in
                        guard pttControlsHydrated else { return }
                        faeCore.patchConfig(
                            key: "voice.push_to_talk_only",
                            payload: ["value": newValue]
                        )
                    }
                Text("Click the orb (or hold the key below) to talk. Continuous listening, wake word and barge-in are bypassed — your speech goes straight to the model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Hold-to-talk key", selection: $pttHotkeySelection) {
                    ForEach(Self.pttHotkeyOptions, id: \.keyCode) { option in
                        Text(option.label).tag(option.keyCode)
                    }
                }
                .onChange(of: pttHotkeySelection) { _, newValue in
                    guard pttControlsHydrated else { return }
                    faeCore.patchConfig(
                        key: "voice.ptt_hotkey_key_code",
                        payload: newValue >= 0 ? ["value": newValue] : [:]
                    )
                }
            }

            Section("Keyboard Shortcuts") {
                HStack {
                    Text("Summon Fae")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text("\u{2303}\u{21E7}A")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
                HStack {
                    Text("Stop Generation")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text("\u{2318}.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
                Text("Summon requires Accessibility permission (granted on first use).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear {
            pushToTalkOnly = faeCore.isPushToTalkOnly()
            pttHotkeySelection = faeCore.pttHotkeyKeyCode() ?? -1
            // Defer the hydrated flag one runloop turn so the assignments
            // above never fire the persisting onChange handlers.
            DispatchQueue.main.async { pttControlsHydrated = true }
        }
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
