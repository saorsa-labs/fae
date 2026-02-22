import SwiftUI

/// Models settings tab: pipeline status and model information.
struct SettingsModelsTab: View {
    var commandSender: HostCommandSender?
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"

    private let voiceModelOptions: [(label: String, value: String, description: String)] = [
        ("Auto (Recommended)", "auto", "Uses Qwen3-4B on systems with at least 32 GB RAM, otherwise Qwen3-1.7B."),
        ("Qwen3-4B", "qwen3_4b", "Higher instruction quality, slightly slower."),
        ("Qwen3-1.7B", "qwen3_1_7b", "Fastest local voice model.")
    ]

    var body: some View {
        Form {
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

            Section("Voice Models") {
                modelRow(label: "TTS Engine", value: "Kokoro-82M")
                modelRow(label: "STT Engine", value: "Parakeet")
            }

            Section("LLM") {
                modelRow(label: "Provider", value: "Local (Embedded)")
                Picker("Voice Model", selection: $voiceModelPreset) {
                    ForEach(voiceModelOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: voiceModelPreset) {
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "llm.voice_model_preset", "value": voiceModelPreset]
                    )
                }

                if let current = voiceModelOptions.first(where: { $0.value == voiceModelPreset }) {
                    Text(current.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modelRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
