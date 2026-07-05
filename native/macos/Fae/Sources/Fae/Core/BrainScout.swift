import Foundation

/// UX W3 — discovers the "other brains" available to Fae so she can speak about
/// them accurately and offer to use them.
///
/// Mirrors ``ToolAugmentationManager``: a scheduled scan (`brain_scout`, 24h +
/// startup) stores the findings as a `fact` memory record and refreshes a compact
/// prompt hint. Three kinds of brain are discovered:
///
/// 1. **ACP agent CLIs on PATH** — the agents `delegate_agent` can drive, resolved
///    by bare name the same way `AgentDelegateTool` does (`/usr/bin/env <bin>`).
/// 2. **Local model servers** — Ollama (`:11434`) and LM Studio (`:1234`), probed
///    on loopback with a 1s timeout; their model lists are parsed.
/// 3. **Cloud provider** — whether an OpenRouter key is configured in the Keychain
///    (existence ONLY; the value is never read, logged, or stored).
///
/// Explicitly OUT of scope by design: NO dotfile scanning, NO environment
/// harvesting, NO key scraping. For a cloud key, Fae *asks* (see the
/// `cloud-brain-setup` skill) — she never goes looking for secrets on disk.
enum BrainScout {

    // MARK: - Findings

    /// The result of one discovery pass. Carries no secret material.
    struct Findings: Sendable, Equatable {
        /// ACP agent binaries found on PATH (e.g. `["codex", "claude"]`).
        var acpAgents: [String] = []
        /// Model names advertised by a local Ollama server on `:11434`.
        var ollamaModels: [String] = []
        /// Model ids advertised by a local LM Studio server on `:1234`.
        var lmStudioModels: [String] = []
        /// Whether an OpenRouter cloud key is configured (existence only).
        var cloudKeyConfigured: Bool = false

        var hasAnyLocalServer: Bool { !ollamaModels.isEmpty || !lmStudioModels.isEmpty }
    }

    /// ACP agent CLIs Fae can delegate to. Same bare names `AgentDelegateTool`
    /// resolves via `/usr/bin/env`; there is no discovery beyond PATH presence.
    static let acpBinaries: [String] = ["codex", "claude", "gemini", "copilot", "pi", "acpx"]

    /// Cached findings from the most recent scan, for the (synchronous, per-turn)
    /// prompt hint. `nil` until the first `brain_scout` scan runs.
    private static let cache = BrainScoutCache()

    // MARK: - Discovery

    /// Run a full discovery pass: ACP PATH probe + local-server probes + cloud-key
    /// existence check. Async because the local-server probes hit loopback with a
    /// 1s timeout each. Updates the prompt-hint cache as a side effect.
    static func scan() async -> Findings {
        var findings = Findings()
        findings.acpAgents = acpBinaries.filter { whichBinary($0) != nil }
        findings.ollamaModels = await probeOllama()
        findings.lmStudioModels = await probeLMStudio()
        findings.cloudKeyConfigured = cloudKeyConfigured()
        cache.set(findings)
        return findings
    }

    /// Whether an OpenRouter cloud key exists in the Keychain. Existence ONLY —
    /// the value is retrieved to test presence, then immediately discarded and
    /// never logged or returned.
    static func cloudKeyConfigured() -> Bool {
        CredentialManager.retrieve(key: "openrouter.apiKey") != nil
    }

    // MARK: - Local server probes

    /// GET `http://127.0.0.1:11434/api/tags` (Ollama). Returns the model names, or
    /// `[]` when no server answers within the timeout or the shape is unexpected.
    static func probeOllama() async -> [String] {
        guard let data = await getLoopback(port: 11434, path: "/api/tags") else { return [] }
        // Ollama shape: { "models": [ { "name": "llama3.1:8b", ... }, ... ] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
    }

    /// GET `http://127.0.0.1:1234/v1/models` (LM Studio, OpenAI shape). Returns the
    /// model ids, or `[]` on timeout / unexpected shape.
    static func probeLMStudio() async -> [String] {
        guard let data = await getLoopback(port: 1234, path: "/v1/models") else { return [] }
        // OpenAI shape: { "data": [ { "id": "..." }, ... ] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Loopback-only GET with a hard 1s timeout. Returns the body on HTTP 200,
    /// `nil` otherwise. Bound to `127.0.0.1` so no traffic ever leaves the machine.
    private static func getLoopback(port: Int, path: String) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.0
        cfg.timeoutIntervalForResource = 1.0
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Memory + prompt rendering

    /// Format the findings as a `fact` memory record body (mirrors
    /// `ToolAugmentationManager.availableToolsSummary`). Content-only, no secrets.
    static func memorySummary(_ f: Findings) -> String {
        var lines: [String] = ["Other brains available to Fae (besides the local model):"]
        if !f.acpAgents.isEmpty {
            lines.append("- ACP agents (delegate via delegate_agent): \(f.acpAgents.joined(separator: ", "))")
        }
        if !f.ollamaModels.isEmpty {
            lines.append("- Local model server (Ollama, 127.0.0.1:11434): \(f.ollamaModels.joined(separator: ", "))")
        }
        if !f.lmStudioModels.isEmpty {
            lines.append("- Local model server (LM Studio, 127.0.0.1:1234): \(f.lmStudioModels.joined(separator: ", "))")
        }
        if f.cloudKeyConfigured {
            lines.append("- Cloud brain (OpenRouter): configured — cloud routing available when the user asks.")
        } else {
            lines.append("- Cloud brain (OpenRouter): not configured — offer the conversational cloud-brain-setup if the user wants a bigger brain for hard questions.")
        }
        if lines.count == 1 {
            return "No other brains detected yet — the local model handles everything. A cloud brain can be added by asking (cloud-brain-setup)."
        }
        return lines.joined(separator: "\n")
    }

    /// Compact prompt fragment from the CACHED findings (synchronous — safe to call
    /// during per-turn prompt assembly; never triggers a network probe). Returns
    /// `nil` until the first scan has run or when nothing is available.
    static func promptFragment() -> String? {
        guard let f = cache.get() else { return nil }
        var parts: [String] = []
        if !f.acpAgents.isEmpty {
            parts.append("ACP agents (delegate_agent): \(f.acpAgents.joined(separator: ", "))")
        }
        if !f.ollamaModels.isEmpty {
            parts.append("Ollama local server (\(f.ollamaModels.count) model\(f.ollamaModels.count == 1 ? "" : "s"))")
        }
        if !f.lmStudioModels.isEmpty {
            parts.append("LM Studio local server (\(f.lmStudioModels.count) model\(f.lmStudioModels.count == 1 ? "" : "s"))")
        }
        parts.append(f.cloudKeyConfigured
            ? "cloud brain (OpenRouter) configured"
            : "cloud brain not set up (offer cloud-brain-setup for hard questions)")
        guard !parts.isEmpty else { return nil }
        return "Other brains available: \(parts.joined(separator: "; ")). Speak about them only if relevant; the local model stays the default."
    }

    // MARK: - Helpers

    /// Resolve a binary name to its absolute path via PATH, or `nil` if absent.
    /// Presence-only: the agent is NOT executed (a `--version` probe would risk
    /// hanging on an interactive agent), so a cheap version is intentionally
    /// skipped. Same PATH `AgentDelegateTool`/`SafeBashExecutor` use.
    private static func whichBinary(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let home = NSHomeDirectory()
        process.environment = [
            "PATH": "\(home)/.local/bin:\(home)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Cache

/// Thread-safe holder for the most recent ``BrainScout/Findings`` so the
/// per-turn prompt hint never triggers a network probe.
final class BrainScoutCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: BrainScout.Findings?

    func get() -> BrainScout.Findings? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func set(_ value: BrainScout.Findings) {
        lock.lock()
        defer { lock.unlock() }
        cached = value
    }
}
