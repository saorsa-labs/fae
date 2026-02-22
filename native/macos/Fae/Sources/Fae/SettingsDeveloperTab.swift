import SwiftUI

/// Developer settings tab: orb controls, raw command input.
/// Hidden unless activated via Option-click or debug flag.
struct SettingsDeveloperTab: View {
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
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
        }
        .formStyle(.grouped)
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
}
