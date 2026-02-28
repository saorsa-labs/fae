import SwiftUI

/// Rich About panel showing version, model stack, system info, changelog, and updates.
struct AboutWindowView: View {
    @ObservedObject var conversation: ConversationController
    @ObservedObject var sparkleUpdater: SparkleUpdaterController
    @ObservedObject var faeCore: FaeCore

    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                Divider()
                modelsSection
                Divider()
                systemSection
                Divider()
                whatsNewSection
                Divider()
                updatesSection

                Text("100% local \u{00B7} No cloud \u{00B7} No tracking")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(24)
        }
        .frame(width: 440, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            Image(nsImage: FaeApp.renderStaticOrb())
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            Text("Fae")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text("v\(appVersion) \u{00B7} Build \(appBuild) \u{00B7} arm64")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("by Saorsa Labs")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Models")

            let model = FaeConfig.recommendedModel()
            let stt = FaeConfig.recommendedSTTModel()
            let tts = FaeConfig.recommendedTTSModel()

            infoRow("LLM", value: formatModelName(model.modelId))
            infoRow("STT", value: formatModelName(stt))
            infoRow("TTS", value: formatModelName(tts))
            infoRow("Speaker", value: "ECAPA-TDNN (Core ML)")
        }
    }

    // MARK: - System

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("System")

            let totalGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
            let model = FaeConfig.recommendedModel()

            infoRow("RAM", value: "\(totalGB) GB")
            infoRow("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            infoRow("Chip", value: chipName)
            infoRow("Context", value: "\(formatNumber(model.contextSize)) tokens")
            infoRow("Pipeline", value: faeCore.pipelineState.label)
        }
    }

    // MARK: - What's New

    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("What's New")

            ForEach(Self.changelog, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Updates")

            HStack {
                Button("Check for Updates") {
                    sparkleUpdater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!sparkleUpdater.canCheckForUpdates)

                Spacer()

                if let lastCheck = sparkleUpdater.lastUpdateCheck {
                    Text("Last checked \(lastCheck, style: .relative) ago")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if sparkleUpdater.isConfigured {
                Toggle("Automatic updates", isOn: Binding(
                    get: { sparkleUpdater.automaticallyChecksForUpdates },
                    set: { sparkleUpdater.automaticallyChecksForUpdates = $0 }
                ))
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Extract a human-readable model name from a HuggingFace repo ID.
    private func formatModelName(_ repoId: String) -> String {
        // "mlx-community/Qwen3-8B-4bit" → "Qwen3-8B · 4bit"
        // "NexVeridian/Qwen3.5-35B-A3B-4bit" → "Qwen3.5-35B-A3B · 4bit"
        let name = repoId.components(separatedBy: "/").last ?? repoId
        // Split on last hyphen-delimited quantization token
        let parts = name.components(separatedBy: "-")
        if parts.count >= 2 {
            let quant = parts.last ?? ""
            let base = parts.dropLast().joined(separator: "-")
            if quant.contains("bit") || quant.contains("bf16") || quant.contains("fp16") {
                return "\(base) \u{00B7} \(quant)"
            }
        }
        return name
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    // MARK: - Static Changelog

    /// Updated per release — keeps the About window informative without parsing files.
    private static let changelog: [String] = [
        "Rescue mode for safe recovery",
        "Personality editor (Edit menu)",
        "Enhanced orb animations with Metal shaders",
        "Streaming conversation bubbles",
        "Global hotkey (Ctrl+Shift+A)",
        "Neural embeddings for semantic memory",
        "Knowledge graph with entity relationships",
    ]
}

// MARK: - Pipeline State Label

extension FaePipelineState {
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }
}
