import SwiftUI

/// Overview dashboard tab - shows system status, quick toggles, and navigation hints.
struct SettingsOverviewTab: View {
    var commandSender: HostCommandSender?

    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager

    // Quick toggles
    @AppStorage("thinkingEnabled") private var thinkingEnabled: Bool = false
    @AppStorage("visionEnabled") private var visionEnabled: Bool = false
    @AppStorage("kvQuantEnabled") private var kvQuantEnabled: Bool = true

    // System info
    @State private var systemRAM: UInt64 = 0
    @State private var loadedModelName: String = "—"
    @State private var memoryUsage: String = "—"
    @State private var tokensPerSecond: String = "—"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                // Status Cards Row
                HStack(spacing: 16) {
                    statusCard(
                        title: "System RAM",
                        value: "\(systemRAM) GB",
                        icon: "memorychip",
                        color: FaeDesign.heatherMistText
                    )

                    modelStackCard

                    statusCard(
                        title: "Memory Saver",
                        value: kvQuantEnabled ? "On" : "Off",
                        icon: "bolt.fill",
                        color: kvQuantEnabled ? FaeDesign.statusSuccess : FaeDesign.statusWarning
                    )
                }

                // Quick Toggles
                quickTogglesSection

                // Feature Highlights
                featureHighlightsSection

                // Tips
                tipsSection
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadSystemInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faePipelineState)) { _ in
            loadSystemInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeRuntimeState)) { _ in
            loadSystemInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeModelLoaded)) { _ in
            loadSystemInfo()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            // Fae Orb Icon
            Circle()
                .fill(
                    RadialGradient(
                        colors: [FaeDesign.cairngormTopaz, FaeDesign.faeGold, FaeDesign.highlandAmber],
                        center: .init(x: 0.4, y: 0.4),
                        startRadius: 0,
                        endRadius: 32
                    )
                )
                .frame(width: 56, height: 56)
                .shadow(color: FaeDesign.faeGold.opacity(0.3), radius: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Fae Settings")
                    .font(.system(size: 22, weight: .regular, design: .serif))

                Text("Configure your AI assistant")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Version Badge
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Status Card

    private func statusCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 18, weight: .bold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modelStackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FaeDesign.heatherMistText)
                Text("Models")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                modelRoleRow(title: "Model", value: loadedModelName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func modelRoleRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Quick Toggles

    private var quickTogglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Toggles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                quickToggle(
                    title: "Deep Thinking",
                    icon: "brain",
                    isOn: $thinkingEnabled,
                    color: FaeDesign.faeGold
                ) {
                    patchConfig("llm.thinking_enabled", value: thinkingEnabled)
                }

                quickToggle(
                    title: "Memory Saver",
                    icon: "bolt.fill",
                    isOn: $kvQuantEnabled,
                    color: FaeDesign.glenGreenText
                ) {
                    patchConfig("llm.kv_quant_bits", value: kvQuantEnabled ? 4 : nil)
                }
            }
        }
    }

    private func quickToggle(
        title: String,
        icon: String,
        isOn: Binding<Bool>,
        color: Color,
        onChange: @escaping () -> Void
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            onChange()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isOn.wrappedValue ? color.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 48, height: 48)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isOn.wrappedValue ? color : .secondary)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature Highlights

    private var featureHighlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optimize Your Experience")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                featureRow(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Performance",
                    description: "Reduce memory usage so Fae can handle longer conversations",
                    tab: "Models & Performance → Performance"
                )

                featureRow(
                    icon: "sparkles",
                    title: "Skills & Channels",
                    description: "Manage integrations and extend Fae's capabilities",
                    tab: "Skills & Channels"
                )

                featureRow(
                    icon: "network.badge.shield.half.filled",
                    title: "Cloud Models",
                    description: "Connect to powerful cloud models when you need more than local",
                    tab: "Other LLMs"
                )

                featureRow(
                    icon: "lock.shield",
                    title: "Privacy Controls",
                    description: "Manage tools, voice identity, and personality",
                    tab: "Privacy & Security"
                )

                featureRow(
                    icon: "eye",
                    title: "Awareness Settings",
                    description: "Configure camera and screen observation",
                    tab: "Awareness"
                )
            }
        }
    }

    private func featureRow(icon: String, title: String, description: String, tab: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(FaeDesign.heatherMistText)
                .frame(width: 32, height: 32)
                .background(FaeDesign.heatherMist.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(tab)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Tips

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tips")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(FaeDesign.faeGoldText)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory optimization is on by default")
                        .font(.system(size: 12, weight: .medium))

                    Text("This lets Fae handle longer conversations without running out of memory on your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FaeDesign.faeGold.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Helpers

    private func loadSystemInfo() {
        systemRAM = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

        let config = FaeConfig.load()
        let defaults = UserDefaults.standard
        let modelId = defaults.string(forKey: "fae.loaded_model_id")
        loadedModelName = LocalModelStatusFormatter.stackSummary(
            loadedModelId: modelId,
            preset: config.llm.voiceModelPreset
        )
    }

    private func patchConfig(_ key: String, value: Any?) {
        if let v = value {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": key, "value": v]
            )
        } else {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": key, "value": NSNull()]
            )
        }
    }
}
