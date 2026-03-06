import SwiftUI

struct SettingsDiagnosticsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case voice = "Voice"
        case about = "About"
        case developer = "Developer"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .voice: return "waveform.and.mic"
            case .about: return "info.circle"
            case .developer: return "hammer"
            }
        }
    }

    var commandSender: HostCommandSender?
    var showDeveloper: Bool

    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController

    @State private var section: Section = .voice
    @State private var wakeTemplateCount: Int = 0
    @State private var acousticWakeEnabled: Bool = true
    @State private var acousticWakeThreshold: Double = 0.78
    @State private var loadedVoiceConfig: Bool = false

    private var availableSections: [Section] {
        showDeveloper ? [.voice, .about, .developer] : [.voice, .about]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picker
                .padding(.horizontal)
                .padding(.top, 8)

            Group {
                switch section {
                case .voice:
                    ScrollView {
                        voiceDiagnostics
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                    }
                case .about:
                    SettingsAboutTab(commandSender: commandSender)
                        .environmentObject(handoff)
                        .environmentObject(onboarding)
                case .developer:
                    if showDeveloper {
                        SettingsDeveloperTab()
                            .environmentObject(orbState)
                            .environmentObject(handoff)
                    }
                }
            }
        }
        .onAppear {
            if !availableSections.contains(section) {
                section = .voice
            }
            if !loadedVoiceConfig {
                loadedVoiceConfig = true
                Task { @MainActor in
                    await loadVoiceConfig()
                }
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            ForEach(availableSections) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        section = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(section == item ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .foregroundColor(section == item ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var voiceDiagnostics: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "Live Voice Pipeline", icon: "waveform.and.mic", color: .blue) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        diagnosticMetric("Pipeline", value: pipelineAux.isPipelineReady ? "Ready" : "Starting")
                        diagnosticMetric("Status", value: pipelineAux.status)
                        diagnosticMetric("Mic RMS", value: String(format: "%.3f", pipelineAux.audioRMS))
                    }

                    ProgressView(value: min(max(pipelineAux.audioRMS * 8.0, 0.0), 1.0))
                        .progressViewStyle(.linear)

                    Text("The RMS meter helps explain whether Fae is hearing clean speech, room noise, or silence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Attention Decision", icon: "ear.badge.checkmark", color: .green) {
                let diagnostics = pipelineAux.voiceAttention
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        badge(diagnostics.lastStage.replacingOccurrences(of: "_", with: " "), color: .blue)
                        badge(diagnostics.lastDecision.replacingOccurrences(of: "_", with: " "), color: .green)
                        badge(diagnostics.lastSpeakerRole, color: .purple)
                        if let semantic = diagnostics.lastSemanticState {
                            badge(semantic, color: .orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        labeledValue("Reason", diagnostics.lastReason.replacingOccurrences(of: "_", with: " "))
                        labeledValue("Transcript", diagnostics.lastTranscript.isEmpty ? "—" : diagnostics.lastTranscript)
                        labeledValue(
                            "Updated",
                            diagnostics.lastUpdatedAt.map { Self.eventDateFormatter.string(from: $0) } ?? "—"
                        )
                    }
                }
            }

            SettingsCard(title: "Wake Word Detector", icon: "bell.badge.waveform", color: .orange) {
                let diagnostics = pipelineAux.voiceAttention
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        diagnosticMetric("Acoustic Wake", value: acousticWakeEnabled ? "On" : "Off")
                        diagnosticMetric("Threshold", value: String(format: "%.2f", acousticWakeThreshold))
                        diagnosticMetric("Samples", value: "\(wakeTemplateCount)")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        labeledValue("Last source", diagnostics.lastWakeSource ?? "text / none")
                        labeledValue(
                            "Last wake score",
                            diagnostics.lastWakeScore.map { String(format: "%.3f", $0) } ?? "—"
                        )
                    }

                    Text(
                        wakeTemplateCount == 0
                            ? "No acoustic wake samples are enrolled yet. Text wake matching still works; collect a few 'Hey Fae' samples to arm audio-level wake detection."
                            : "Acoustic wake detection runs before STT and is conservative by design. If it misses too often, lower the threshold slightly."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Recent Attention Events", icon: "list.bullet.rectangle", color: .indigo) {
                let events = pipelineAux.voiceAttention.recentEvents
                if events.isEmpty {
                    Text("No voice attention events yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(events.prefix(8)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(Self.eventTimeFormatter.string(from: event.timestamp))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    badge(event.stage, color: .blue)
                                    badge(event.decision, color: .green)
                                    if let source = event.wakeSource {
                                        badge(source, color: .orange)
                                    }
                                }

                                Text(event.reason.replacingOccurrences(of: "_", with: " "))
                                    .font(.subheadline.weight(.medium))

                                if let transcript = event.transcript, !transcript.isEmpty {
                                    Text(transcript)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                            if event.id != events.prefix(8).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func diagnosticMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @MainActor
    private func loadVoiceConfig() async {
        guard let sender = commandSender as? FaeCore else { return }
        guard let response = await sender.queryCommand(name: "config.get", payload: ["key": "conversation"]) else {
            return
        }
        guard let payload = response["payload"] as? [String: Any],
              let conversation = payload["conversation"] as? [String: Any]
        else {
            return
        }

        if let enabled = conversation["acoustic_wake_enabled"] as? Bool {
            acousticWakeEnabled = enabled
        }
        if let threshold = conversation["acoustic_wake_threshold"] as? Double {
            acousticWakeThreshold = threshold
        }
        if let templateCount = conversation["wake_template_count"] as? Int {
            wakeTemplateCount = templateCount
        }
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
