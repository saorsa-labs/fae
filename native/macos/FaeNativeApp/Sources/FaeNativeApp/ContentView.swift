import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var handoff: DeviceHandoffController
    @StateObject private var audio = AudioDeviceController()

    @State private var orbMode: OrbMode = .idle
    @State private var orbPalette: OrbPalette = .modeDefault
    @State private var commandText: String = ""

    var body: some View {
        VStack(spacing: 18) {
            header

            OrbWebView(mode: orbMode, palette: orbPalette)
                .frame(maxWidth: .infinity)
                .frame(height: 430)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack {
                Text("Orb State")
                    .foregroundStyle(.secondary)
                Picker("Orb State", selection: $orbMode) {
                    ForEach(OrbMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Text("Orb Palette")
                    .foregroundStyle(.secondary)
                Picker("Orb Palette", selection: $orbPalette) {
                    ForEach(OrbPalette.allCases) { palette in
                        Text(palette.label).tag(palette)
                    }
                }
            }

            handoffCard
            audioCard
        }
        .padding(20)
        .background(Color.black.opacity(0.98))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fae Native")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(handoff.handoffStateText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Target: \(handoff.currentTarget.label)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
    }

    private var handoffCard: some View {
        GroupBox("Cross-Device Handoff") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([DeviceTarget.watch, DeviceTarget.iphone, DeviceTarget.mac]) { target in
                        Button("Move to \(target.label)") {
                            if target == .mac {
                                handoff.goHome(sourceCommand: "go home")
                                orbMode = .idle
                            } else {
                                handoff.move(to: target, sourceCommand: "move to my \(target.label.lowercased())")
                                orbMode = .listening
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack(spacing: 8) {
                    TextField(
                        "Try: move to my watch, set moss stone, set peat earth, go home",
                        text: $commandText
                    )
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        applyCommand(commandText)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }

                Text("Last command: \(handoff.lastCommandText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var audioCard: some View {
        GroupBox("Native Audio Routing") {
            VStack(alignment: .leading, spacing: 10) {
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
                        Text("Microphone access is required for always-listening mode.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open Microphone Privacy Settings") {
                            openMicrophonePrivacySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack {
                    Text("Output Route")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    AudioRoutePicker()
                        .frame(width: 34, height: 22)
                    Spacer()
                    Text("Mic: \(audio.selectedInputName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private func applyCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if let palette = OrbPalette.commandOverride(in: trimmed) {
            orbPalette = palette
            handoff.note(commandText: "Orb palette set to \(palette.label)")
            commandText = ""
            return
        }

        if let mode = OrbMode.commandOverride(in: trimmed) {
            orbMode = mode
            handoff.note(commandText: "Orb mode set to \(mode.label)")
            commandText = ""
            return
        }

        let result = handoff.execute(commandText: raw)
        switch result {
        case .move(let target):
            orbMode = target == .watch ? .speaking : .listening
        case .goHome:
            orbMode = .idle
        case .unsupported:
            orbMode = .thinking
        }
        commandText = ""
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
