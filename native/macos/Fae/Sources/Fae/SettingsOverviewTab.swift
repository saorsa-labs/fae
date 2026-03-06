import SwiftUI

/// Overview dashboard tab - shows system status, quick toggles, and navigation hints.
struct SettingsOverviewTab: View {
    var commandSender: HostCommandSender?

    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager

    // Quick toggles
    @AppStorage("thinkingEnabled") private var thinkingEnabled: Bool = false
    @AppStorage("visionEnabled") private var visionEnabled: Bool = false
    @AppStorage("bargeInEnabled") private var bargeInEnabled: Bool = true
    @AppStorage("kvQuantEnabled") private var kvQuantEnabled: Bool = true
    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"

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
                        color: .blue
                    )

                    statusCard(
                        title: "Model",
                        value: loadedModelName,
                        icon: "cpu",
                        color: .purple
                    )

                    statusCard(
                        title: "KV Cache",
                        value: kvQuantEnabled ? "4-bit" : "16-bit",
                        icon: "bolt.fill",
                        color: kvQuantEnabled ? .green : .orange
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
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            // Fae Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.8), .blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)

                Text("🧚")
                    .font(.system(size: 32))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Fae Settings")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text("Configure your AI assistant")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Version Badge
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
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
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Quick Toggles

    private var quickTogglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Toggles")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                quickToggle(
                    title: "Thinking",
                    icon: "brain",
                    isOn: $thinkingEnabled,
                    color: .orange
                ) {
                    patchConfig("llm.thinking_enabled", value: thinkingEnabled)
                }

                quickToggle(
                    title: "Vision",
                    icon: "eye",
                    isOn: $visionEnabled,
                    color: .purple
                ) {
                    patchConfig("vision.enabled", value: visionEnabled)
                }

                quickToggle(
                    title: "Barge-In",
                    icon: "hand.raised",
                    isOn: $bargeInEnabled,
                    color: .teal
                ) {
                    patchConfig("barge_in.enabled", value: bargeInEnabled)
                }

                quickToggle(
                    title: "KV Quant",
                    icon: "bolt.fill",
                    isOn: $kvQuantEnabled,
                    color: .green
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
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                featureRow(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Performance Tuning",
                    description: "Configure KV cache quantization for 4x memory savings",
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
                    title: "Other LLMs",
                    description: "Set up OpenRouter once and choose from many remote models safely",
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.1))
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
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 4) {
                    Text("4-bit KV quantization is now enabled by default")
                        .font(.system(size: 12, weight: .medium))

                    Text("This reduces memory usage by ~4x, allowing larger contexts and longer conversations without running out of RAM.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Helpers

    private func loadSystemInfo() {
        systemRAM = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

        // Get model name
        if let model = UserDefaults.standard.string(forKey: "fae.loaded_model_id") {
            loadedModelName = model.components(separatedBy: "/").last ?? model
        } else if voiceModelPreset == "auto" {
            // Estimate based on RAM
            let (modelId, _) = FaeConfig.recommendedModel()
            loadedModelName = modelId.components(separatedBy: "/").last ?? "Auto"
        } else {
            loadedModelName = voiceModelPreset
        }
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
