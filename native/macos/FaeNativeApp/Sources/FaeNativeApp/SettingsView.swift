import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @StateObject private var audio = AudioDeviceController()
    @State private var commandText: String = ""

    var body: some View {
        Form {
            Section("Orb Controls") {
                Picker("Mode", selection: $orbState.mode) {
                    ForEach(OrbMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Palette", selection: $orbState.palette) {
                    ForEach(OrbPalette.allCases) { palette in
                        Text(palette.label).tag(palette)
                    }
                }

                Picker("Feeling", selection: $orbState.feeling) {
                    ForEach(OrbFeeling.allCases) { feeling in
                        Text(feeling.label).tag(feeling)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Commands") {
                HStack(spacing: 8) {
                    TextField("Enter command...", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        applyCommand(commandText)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Last: \(handoff.lastCommandText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Cross-Device Handoff") {
                HStack(spacing: 8) {
                    ForEach([DeviceTarget.watch, DeviceTarget.iphone, DeviceTarget.mac]) { target in
                        Button("Move to \(target.label)") {
                            if target == .mac {
                                handoff.goHome(sourceCommand: "go home")
                                orbState.mode = .idle
                            } else {
                                handoff.move(
                                    to: target,
                                    sourceCommand: "move to my \(target.label.lowercased())"
                                )
                                orbState.mode = .listening
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text(handoff.handoffStateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                HStack {
                    Text("Input Device")
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

                Divider()

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
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 400)
    }

    private func applyCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let palette = OrbPalette.commandOverride(in: trimmed) {
            orbState.palette = palette
            handoff.note(commandText: "Orb palette set to \(palette.label)")
            commandText = ""
            return
        }

        if let mode = OrbMode.commandOverride(in: trimmed) {
            orbState.mode = mode
            handoff.note(commandText: "Orb mode set to \(mode.label)")
            commandText = ""
            return
        }

        if let feeling = OrbFeeling.commandOverride(in: trimmed) {
            orbState.feeling = feeling
            handoff.note(commandText: "Orb feeling set to \(feeling.label)")
            commandText = ""
            return
        }

        let result = handoff.execute(commandText: raw)
        switch result {
        case .move(let target):
            orbState.mode = target == .watch ? .speaking : .listening
        case .goHome:
            orbState.mode = .idle
        case .unsupported:
            orbState.mode = .thinking
        }
        commandText = ""
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
