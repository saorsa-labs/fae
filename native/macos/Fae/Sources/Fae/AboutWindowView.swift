import SwiftUI

/// Rich About panel showing version, model stack, system info, and changelog.
///
/// Updates are handled by the Fae menu "Check for Updates..." item (Sparkle).
/// The About window focuses on system info and release history.
struct AboutWindowView: View {
    @ObservedObject var conversation: ConversationRuntimeController
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
                changelogSection

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

            let config = FaeConfig.load()
            let model = FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset)

            infoRow("LLM", value: formatModelName(model.modelId))
            infoRow("STT", value: "Qwen3-ASR-1.7B")
            infoRow("TTS", value: "Kokoro-82M")
            infoRow("Speaker", value: "ECAPA-TDNN (Core ML)")
        }
    }

    // MARK: - System

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("System")

            let totalGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
            infoRow("RAM", value: "\(totalGB) GB")
            infoRow("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            infoRow("Chip", value: chipName)
            let config = FaeConfig.load()
            let recommended = FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset)
            infoRow("Context", value: "\(formatNumber(recommended.contextSize)) tokens")
            infoRow("Pipeline", value: faeCore.pipelineState.label)
        }
    }

    // MARK: - Changelog

    private var changelogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Changelog")

            let releases = Self.parsedChangelog
            if releases.isEmpty {
                Text("No changelog available.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(releases.enumerated()), id: \.offset) { _, release in
                    releaseView(release)
                }
            }
        }
    }

    private func releaseView(_ release: ChangelogRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.version)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                if let date = release.date {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
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

    // MARK: - Changelog Parsing

    struct ChangelogRelease {
        let version: String
        let date: String?
        let items: [String]
    }

    /// Parse CHANGELOG.md from the app bundle (or project root in dev).
    /// Shows the 10 most recent releases to keep the About window manageable.
    private static let parsedChangelog: [ChangelogRelease] = {
        guard let text = loadChangelogText() else { return [] }
        return parseChangelog(text, maxReleases: 10)
    }()

    private static func loadChangelogText() -> String? {
        // 1. Try the resource bundle (release builds).
        if let url = Bundle.faeResources.url(forResource: "CHANGELOG", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8)
        {
            return text
        }

        // 2. Try project root (dev builds via `just run-native`).
        let devPaths = [
            // Running from native/macos/Fae/.build/...
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Fae/
                .deletingLastPathComponent() // Sources/
                .deletingLastPathComponent() // Fae/
                .deletingLastPathComponent() // macos/
                .deletingLastPathComponent() // native/
                .appendingPathComponent("CHANGELOG.md"),
        ]
        for path in devPaths {
            if let text = try? String(contentsOf: path, encoding: .utf8) {
                return text
            }
        }

        return nil
    }

    /// Parse a CHANGELOG.md into structured releases.
    ///
    /// Expected format:
    /// ```
    /// ## [v0.8.112] - 2026-03-16
    /// ### Added
    /// - Item one
    /// - Item two
    /// ### Fixed
    /// - Fix one
    /// ```
    private static func parseChangelog(_ text: String, maxReleases: Int) -> [ChangelogRelease] {
        var releases: [ChangelogRelease] = []
        var currentVersion: String?
        var currentDate: String?
        var currentItems: [String] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Version header: ## [v0.8.112] - 2026-03-16
            if trimmed.hasPrefix("## [") {
                // Save previous release.
                if let version = currentVersion, !currentItems.isEmpty {
                    releases.append(ChangelogRelease(
                        version: version,
                        date: currentDate,
                        items: currentItems
                    ))
                    if releases.count >= maxReleases { break }
                }

                // Parse new version.
                let afterBracket = trimmed.dropFirst(4) // drop "## ["
                if let closeBracket = afterBracket.firstIndex(of: "]") {
                    currentVersion = String(afterBracket[afterBracket.startIndex..<closeBracket])
                    let rest = afterBracket[closeBracket...].dropFirst() // drop "]"
                    let dateStr = rest.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                    currentDate = dateStr.isEmpty ? nil : dateStr
                } else {
                    currentVersion = String(afterBracket)
                    currentDate = nil
                }
                currentItems = []
                continue
            }

            // Skip section headers (### Added, ### Fixed, etc.) — we flatten them.
            if trimmed.hasPrefix("### ") { continue }

            // Bullet item: - **Bold**: description or - plain text
            if trimmed.hasPrefix("- ") {
                var item = String(trimmed.dropFirst(2))
                // Strip markdown bold markers for clean display.
                item = item.replacingOccurrences(
                    of: "\\*\\*(.+?)\\*\\*",
                    with: "$1",
                    options: .regularExpression
                )
                currentItems.append(item)
            }
        }

        // Don't forget the last release.
        if let version = currentVersion, !currentItems.isEmpty, releases.count < maxReleases {
            releases.append(ChangelogRelease(
                version: version,
                date: currentDate,
                items: currentItems
            ))
        }

        return releases
    }
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
