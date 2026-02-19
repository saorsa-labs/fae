import AppKit
import AVKit
import SwiftUI

/// General settings tab: audio input/output and window behavior.
struct SettingsGeneralTab: View {
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @StateObject private var audio = AudioDeviceController()

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

            Section("Window Behavior") {
                Toggle("Auto-hide conversation & canvas when orb collapses",
                       isOn: $auxiliaryWindows.autoHideOnCollapse)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("When enabled, the conversation and canvas windows will automatically hide when the orb collapses after inactivity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
