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
    @State private var isRefreshingVoiceConfig: Bool = false

    private var availableSections: [Section] {
        showDeveloper ? [.voice, .about, .developer] : [.voice, .about]
    }

    private var diagnostics: PipelineAuxBridgeController.VoiceAttentionDiagnostics {
        pipelineAux.voiceAttention
    }

    private var recentEvents: [PipelineAuxBridgeController.VoiceAttentionEvent] {
        Array(diagnostics.recentEvents.prefix(8))
    }

    private var micLevel: Double {
        min(max(pipelineAux.audioRMS * 8.0, 0.0), 1.0)
    }

    private var detectorStatusText: String {
        guard acousticWakeEnabled else { return "Disabled" }
        return wakeTemplateCount > 0 ? "Armed" : "Needs samples"
    }

    private var detectorStatusColor: Color {
        if !acousticWakeEnabled { return .secondary }
        return wakeTemplateCount > 0 ? .green : .orange
    }

    private var listeningStateText: String {
        if pipelineAux.audioRMS > 0.03 {
            return "Hearing speech"
        } else if pipelineAux.isPipelineReady {
            return "Quiet / idle"
        } else {
            return "Starting up"
        }
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
            heroCard

            HStack(alignment: .top, spacing: 20) {
                pipelineHealthCard
                    .frame(maxWidth: .infinity, alignment: .leading)

                attentionDecisionCard
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 20) {
                wakeDetectorCard
                    .frame(maxWidth: .infinity, alignment: .leading)

                guidanceCard
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            recentEventsCard
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.blue.opacity(0.14),
                            Color.purple.opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.white.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Voice attention diagnostics")
                            .font(.system(size: 24, weight: .bold, design: .rounded))

                        Text("See why Fae woke, listened, ignored a segment, or merged a follow-up turn — including acoustic wake decisions before STT.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button {
                        Task { @MainActor in
                            await loadVoiceConfig(forceRefresh: true)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isRefreshingVoiceConfig ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise")
                                .rotationEffect(.degrees(isRefreshingVoiceConfig ? 360 : 0))
                                .animation(
                                    isRefreshingVoiceConfig
                                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                        : .default,
                                    value: isRefreshingVoiceConfig
                                )
                            Text("Refresh")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 12) {
                    heroMetric(title: "Pipeline", value: pipelineAux.isPipelineReady ? "Ready" : "Starting", tint: .blue)
                    heroMetric(title: "Listening", value: listeningStateText, tint: .cyan)
                    heroMetric(title: "Wake detector", value: detectorStatusText, tint: detectorStatusColor)
                    heroMetric(title: "Last decision", value: prettify(diagnostics.lastDecision), tint: color(forDecision: diagnostics.lastDecision))
                }
            }
            .padding(20)
        }
    }

    private var pipelineHealthCard: some View {
        SettingsCard(title: "Live pipeline", icon: "waveform.and.mic", color: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    diagnosticMetric("Status", value: pipelineAux.status)
                    diagnosticMetric("Mic RMS", value: String(format: "%.3f", pipelineAux.audioRMS))
                    diagnosticMetric("Follow-up", value: diagnostics.lastDecision == "accepted" ? "Warm" : "Watching")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Input energy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(listeningStateText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(forMicLevel: micLevel))
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.green, Color.yellow, Color.orange],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(8, proxy.size.width * micLevel))
                        }
                    }
                    .frame(height: 10)
                }

                Text("The RMS meter helps distinguish silence, room noise, and real speech entering the attention pipeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attentionDecisionCard: some View {
        SettingsCard(title: "Attention decision", icon: "ear.badge.checkmark", color: .green) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    decisionPill(prettify(diagnostics.lastDecision), color: color(forDecision: diagnostics.lastDecision))
                    decisionPill(prettify(diagnostics.lastStage), color: .blue)
                    decisionPill(diagnostics.lastSpeakerRole.capitalized, color: .purple)
                    if let semantic = diagnostics.lastSemanticState {
                        decisionPill(prettify(semantic), color: .orange)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    labeledValue("Why", prettify(diagnostics.lastReason))
                    labeledValue("Transcript", diagnostics.lastTranscript.isEmpty ? "—" : diagnostics.lastTranscript)
                    labeledValue(
                        "Updated",
                        diagnostics.lastUpdatedAt.map { Self.eventDateFormatter.string(from: $0) } ?? "—"
                    )
                }
            }
        }
    }

    private var wakeDetectorCard: some View {
        SettingsCard(title: "Wake detector", icon: "bell.badge.waveform", color: .orange) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    diagnosticMetric("Acoustic", value: acousticWakeEnabled ? "On" : "Off")
                    diagnosticMetric("Threshold", value: String(format: "%.2f", acousticWakeThreshold))
                    diagnosticMetric("Templates", value: "\(wakeTemplateCount)")
                }

                HStack(spacing: 8) {
                    decisionPill(diagnostics.lastWakeSource.map(prettify) ?? "Text / none", color: .orange)
                    if let score = diagnostics.lastWakeScore {
                        decisionPill(String(format: "score %.3f", score), color: score >= acousticWakeThreshold ? .green : .secondary)
                    } else {
                        decisionPill("No recent score", color: .secondary)
                    }
                }

                Text(
                    wakeTemplateCount == 0
                        ? "No acoustic wake samples are enrolled yet. Text wake matching still works, but a few 'Hey Fae' samples will unlock pre-STT wake detection."
                        : "Acoustic wake runs before STT and stays conservative. Lower the threshold slightly if it misses genuine wake attempts; raise it if TV or nearby voices slip through."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var guidanceCard: some View {
        SettingsCard(title: "What to look for", icon: "sparkles.rectangle.stack", color: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                guidanceRow(
                    icon: "bell.badge.waveform",
                    title: "Wake misses",
                    detail: "If the source stays 'text / none' and templates are zero, run wake-sample tuning first."
                )
                guidanceRow(
                    icon: "waveform.path.ecg",
                    title: "False activations",
                    detail: "If RMS is high but decisions stay 'wake', raise the acoustic threshold or collect cleaner samples."
                )
                guidanceRow(
                    icon: "arrow.triangle.branch",
                    title: "Merged follow-ups",
                    detail: "A semantic state of 'held' or 'merged' means the semantic turn detector saved an unfinished sentence."
                )
            }
        }
    }

    private var recentEventsCard: some View {
        SettingsCard(title: "Recent attention events", icon: "list.bullet.rectangle", color: .indigo) {
            if recentEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No voice attention events yet.")
                        .font(.subheadline.weight(.medium))
                    Text("Start a voice interaction and this timeline will explain what the attention stack decided.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recentEvents.enumerated()), id: \.element.id) { index, event in
                        voiceEventRow(event)
                            .padding(.vertical, 10)
                        if index < recentEvents.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func heroMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.18))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func diagnosticMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
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

    private func decisionPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func guidanceRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 24, height: 24)
                .background(Color.indigo.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func voiceEventRow(_ event: PipelineAuxBridgeController.VoiceAttentionEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(Self.eventTimeFormatter.string(from: event.timestamp))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                decisionPill(prettify(event.stage), color: .blue)
                decisionPill(prettify(event.decision), color: color(forDecision: event.decision))

                if let source = event.wakeSource {
                    decisionPill(prettify(source), color: .orange)
                }

                Spacer()

                if let rms = event.rms {
                    Text(String(format: "RMS %.3f", rms))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(prettify(event.reason))
                .font(.subheadline.weight(.medium))

            if let transcript = event.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func prettify(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
    }

    private func color(forDecision decision: String) -> Color {
        switch decision {
        case "wake", "accepted", "detected": return .green
        case "held", "merged", "flushed": return .orange
        case let value where value.contains("drop") || value.contains("ignore") || value.contains("ignored"):
            return .red
        default:
            return .secondary
        }
    }

    private func color(forMicLevel level: Double) -> Color {
        switch level {
        case ..<0.08: return .secondary
        case ..<0.35: return .green
        case ..<0.70: return .orange
        default: return .red
        }
    }

    @MainActor
    private func loadVoiceConfig(forceRefresh: Bool = false) async {
        if isRefreshingVoiceConfig { return }
        isRefreshingVoiceConfig = true
        defer { isRefreshingVoiceConfig = false }

        if forceRefresh {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

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
