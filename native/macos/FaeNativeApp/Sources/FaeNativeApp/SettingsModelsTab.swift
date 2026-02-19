import SwiftUI

/// Models settings tab: pipeline status and model information.
struct SettingsModelsTab: View {
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController

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
                modelRow(label: "Provider", value: "Local / API")
                Text("LLM configuration is managed via config.toml.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
