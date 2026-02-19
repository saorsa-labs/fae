import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
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
                Toggle("Enable Handoff", isOn: $handoff.handoffEnabled)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("Transfer conversations between your Apple devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if handoff.handoffEnabled {
                HStack {
                    Image(systemName: handoff.currentTarget.systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current: \(handoff.currentTarget.label)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(handoff.handoffStateText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .accessibilityLabel("Current device: \(handoff.currentTarget.label)")

                HStack(spacing: 8) {
                    ForEach([DeviceTarget.watch, DeviceTarget.iphone, DeviceTarget.mac]) { target in
                        Button {
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
                        } label: {
                            Label(target.label, systemImage: target.systemImage)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Transfer to \(target.label)")
                    }
                }
                } // if handoffEnabled
            }

            Section("Window Behavior") {
                Toggle("Auto-hide conversation & canvas when orb collapses",
                       isOn: $auxiliaryWindows.autoHideOnCollapse)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("When enabled, the conversation and canvas windows will automatically hide when the orb collapses after inactivity.")
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
            Section("Pipeline") {
                HStack {
                    Text("Status")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(pipelineAux.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Audio RMS")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    ProgressView(value: pipelineAux.audioRMS, total: 1.0)
                        .frame(width: 100)
                    Text(String(format: "%.2f", pipelineAux.audioRMS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
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
