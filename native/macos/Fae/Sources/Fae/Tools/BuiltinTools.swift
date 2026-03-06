import Foundation

// MARK: - Read Tool

struct ReadTool: Tool {
    let name = "read"
    let description = "Read the contents of a file at the given path."
    let parametersSchema = #"{"path": "string (required)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"read","arguments":{"path":"~/Documents/notes.txt"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String else {
            return .error("Missing required parameter: path")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .error("File not found: \(path)")
        }
        do {
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            let truncated = content.count > 50_000
                ? String(content.prefix(50_000)) + "\n[truncated]"
                : content
            return .success(truncated)
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Write Tool

struct WriteTool: Tool {
    let name = "write"
    let description = "Write content to a file at the given path."
    let parametersSchema = #"{"path": "string (required)", "content": "string (required)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"write","arguments":{"path":"~/notes.txt","content":"Hello world"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String
        else {
            return .error("Missing required parameters: path, content")
        }

        // Validate write path against blocklist.
        switch PathPolicy.validateWritePath(path) {
        case .blocked(let reason):
            return .error(reason)
        case .allowed(let canonical):
            do {
                let dir = (canonical as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
                let (sanitized, _) = InputSanitizer.sanitizeContentInput(content)
                try sanitized.write(toFile: canonical, atomically: true, encoding: .utf8)
                return .success("Written \(sanitized.count) bytes to \(path)")
            } catch {
                return .error("Failed to write file: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Edit Tool

struct EditTool: Tool {
    let name = "edit"
    let description = "Replace a string in a file. The old_string must match exactly."
    let parametersSchema = #"{"path": "string", "old_string": "string", "new_string": "string"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"edit","arguments":{"path":"~/config.toml","old_string":"timeout = 30","new_string":"timeout = 60"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String,
              let oldString = input["old_string"] as? String,
              let newString = input["new_string"] as? String
        else {
            return .error("Missing required parameters: path, old_string, new_string")
        }

        // Validate write path against blocklist.
        switch PathPolicy.validateWritePath(path) {
        case .blocked(let reason):
            return .error(reason)
        case .allowed(let canonical):
            do {
                let content = try String(contentsOfFile: canonical, encoding: .utf8)
                guard content.contains(oldString) else {
                    return .error("old_string not found in file")
                }

                // Count occurrences for safety reporting.
                let count = content.components(separatedBy: oldString).count - 1

                // Replace only the first occurrence.
                guard let range = content.range(of: oldString) else {
                    return .error("old_string not found in file")
                }
                let updated = content.replacingCharacters(in: range, with: newString)
                try updated.write(
                    toFile: canonical, atomically: true, encoding: String.Encoding.utf8
                )

                if count > 1 {
                    return .success("Replaced first of \(count) occurrences in \(path)")
                }
                return .success("Replaced in \(path)")
            } catch {
                return .error("Edit failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Bash Tool

struct BashTool: Tool {
    let name = "bash"
    let description = "Execute a shell command and return its output."
    let parametersSchema = #"{"command": "string (required)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"bash","arguments":{"command":"ls -la ~/Documents"}}</tool_call>"#

    /// Approval description including command classification.
    ///
    /// Called by `PipelineCoordinator` to build a richer approval card.
    static func approvalDescription(for command: String) -> String {
        if let warning = InputSanitizer.classifyBashCommand(command) {
            return "\(warning)\nCommand: \(command)"
        }
        return "Command: \(command)"
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let command = input["command"] as? String else {
            return .error("Missing required parameter: command")
        }

        do {
            let (status, outData, errData) = try await SafeBashExecutor.execute(
                command: command,
                timeoutSeconds: 30
            )
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            // Log stderr internally but don't expose raw error details to LLM.
            if !errStr.isEmpty {
                NSLog("BashTool stderr for '%@': %@", command, errStr)
            }

            let truncated = outStr.count > 20_000
                ? String(outStr.prefix(20_000)) + "\n[truncated]"
                : outStr

            if status != 0 {
                return .error("Command failed with exit code \(status)")
            }
            return .success(truncated)
        } catch {
            return .error("Failed to execute: \(error.localizedDescription)")
        }
    }

}

// MARK: - Self Config Tool

struct SelfConfigTool: Tool {
    let name = "self_config"
    let description = """
        Manage Fae's behavior settings and standing directives. \
        Actions: adjust_setting (change a live setting like speed, temperature, thinking mode), \
        get_settings (view all adjustable settings and current values), \
        get_directive, set_directive, append_directive, clear_directive (manage standing orders). \
        Legacy aliases: get_instructions, set_instructions, append_instructions, clear_instructions.
        """
    let parametersSchema = #"""
        {"action": "string (required: adjust_setting|get_settings|get_directive|set_directive|append_directive|clear_directive)", "key": "string (required for adjust_setting)", "value": "any (required for adjust_setting and set/append)"}
        """#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"self_config","arguments":{"action":"adjust_setting","key":"tts.speed","value":1.2}}</tool_call>"#

    /// Maximum character length for directive.
    private static let maxInstructionLength = 4000

    /// Callback to FaeCore.patchConfig — set by FaeCore at startup.
    @MainActor static var configPatcher: ((String, Any) -> Void)?

    /// Specification for an adjustable setting — type, range, and human description.
    private struct SettingSpec {
        enum ValueType {
            case float(min: Float, max: Float)
            case bool
            case int(min: Int, max: Int)
            case string(allowed: [String])
        }

        let valueType: ValueType
        let description: String

        func validate(_ value: Any) -> String? {
            switch valueType {
            case .float(let min, let max):
                guard let f = coerceFloat(value) else {
                    return "Expected a number between \(min) and \(max)"
                }
                guard f >= min, f <= max else {
                    return "Value \(f) out of range [\(min), \(max)]"
                }
                return nil
            case .bool:
                if value is Bool { return nil }
                if let s = value as? String, ["true", "false"].contains(s.lowercased()) { return nil }
                return "Expected true or false"
            case .int(let min, let max):
                guard let i = coerceInt(value) else {
                    return "Expected an integer between \(min) and \(max)"
                }
                guard i >= min, i <= max else {
                    return "Value \(i) out of range [\(min), \(max)]"
                }
                return nil
            case .string(let allowed):
                guard let s = coerceString(value) else {
                    return "Expected one of: \(allowed.joined(separator: ", "))"
                }
                guard allowed.contains(s) else {
                    return "Invalid value '\(s)'. Allowed: \(allowed.joined(separator: ", "))"
                }
                return nil
            }
        }

        func coerce(_ value: Any) -> Any {
            switch valueType {
            case .float: return coerceFloat(value) as Any
            case .bool:
                if let b = value as? Bool { return b }
                if let s = value as? String { return s.lowercased() == "true" }
                return value
            case .int: return coerceInt(value) as Any
            case .string: return coerceString(value) as Any
            }
        }

        private func coerceFloat(_ value: Any) -> Float? {
            if let f = value as? Float { return f }
            if let d = value as? Double { return Float(d) }
            if let i = value as? Int { return Float(i) }
            if let s = value as? String { return Float(s) }
            return nil
        }

        private func coerceInt(_ value: Any) -> Int? {
            if let i = value as? Int { return i }
            if let d = value as? Double { return Int(d) }
            if let f = value as? Float { return Int(f) }
            if let s = value as? String { return Int(s) }
            return nil
        }

        private func coerceString(_ value: Any) -> String? {
            guard let s = value as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Adjustable settings allow-list with type, range, and description.
    private static let adjustableKeys: [String: SettingSpec] = [
        "tts.speed": SettingSpec(
            valueType: .float(min: 0.8, max: 1.4),
            description: "Speaking speed (0.8=slow, 1.0=normal, 1.4=fast)"
        ),
        "tts.voice_identity_lock": SettingSpec(
            valueType: .bool,
            description: "Force canonical bundled fae.wav voice"
        ),
        "llm.temperature": SettingSpec(
            valueType: .float(min: 0.3, max: 1.0),
            description: "Creativity (0.3=precise, 0.7=balanced, 1.0=creative)"
        ),
        "llm.thinking_enabled": SettingSpec(
            valueType: .bool,
            description: "Extended reasoning mode"
        ),
        "barge_in.enabled": SettingSpec(
            valueType: .bool,
            description: "Allow user to interrupt mid-speech"
        ),
        "conversation.require_direct_address": SettingSpec(
            valueType: .bool,
            description: "Only respond when addressed by name"
        ),
        "conversation.direct_address_followup_s": SettingSpec(
            valueType: .int(min: 5, max: 60),
            description: "Seconds to keep listening after name-addressed (5-60)"
        ),
        "tool_mode": SettingSpec(
            valueType: .string(allowed: ["off", "read_only", "read_write", "full", "full_no_approval"]),
            description: "Maximum tool authority level"
        ),
        "privacy.mode": SettingSpec(
            valueType: .string(allowed: ["strict_local", "local_preferred", "connected"]),
            description: "Privacy boundary for networking and delegation"
        ),
        "vision.enabled": SettingSpec(
            valueType: .bool,
            description: "Enable vision tools (screenshot, camera, read_screen). Requires restart."
        ),
        "vision.model_preset": SettingSpec(
            valueType: .string(allowed: ["auto", "qwen3_vl_4b_4bit", "qwen3_vl_4b_8bit"]),
            description: "Vision model preset (auto, qwen3_vl_4b_4bit, qwen3_vl_4b_8bit)."
        ),
        "awareness.enabled": SettingSpec(
            valueType: .bool,
            description: "Master toggle for proactive awareness (requires consent)"
        ),
        "awareness.consent_granted": SettingSpec(
            valueType: .bool,
            description: "Explicit consent gate for proactive camera/screen observations"
        ),
        "awareness.camera_enabled": SettingSpec(
            valueType: .bool,
            description: "Camera-based presence detection and greetings"
        ),
        "awareness.screen_enabled": SettingSpec(
            valueType: .bool,
            description: "Screen activity monitoring for contextual help"
        ),
        "awareness.camera_interval_seconds": SettingSpec(
            valueType: .int(min: 10, max: 120),
            description: "Camera check interval in seconds (10-120)"
        ),
        "awareness.screen_interval_seconds": SettingSpec(
            valueType: .int(min: 10, max: 120),
            description: "Screen check interval in seconds (10-120)"
        ),
        "awareness.overnight_work": SettingSpec(
            valueType: .bool,
            description: "Research topics during quiet hours (22:00-06:00)"
        ),
        "awareness.enhanced_briefing": SettingSpec(
            valueType: .bool,
            description: "Enhanced morning briefing with calendar, mail, and research"
        ),
        "awareness.pause_on_battery": SettingSpec(
            valueType: .bool,
            description: "Pause proactive observations when on battery power"
        ),
        "awareness.pause_on_thermal_pressure": SettingSpec(
            valueType: .bool,
            description: "Pause proactive observations under high thermal pressure"
        ),
    ]

    /// Patterns that indicate an attempt to bypass safety.
    private static let jailbreakPatterns: [String] = [
        "ignore safety",
        "bypass approval",
        "without confirmation",
        "disable safety",
        "always execute",
        "no restrictions",
        "override security",
        "ignore all rules",
        "bypass security",
        "skip approval",
        "disable approval",
        "unrestricted access",
        "ignore instructions",
        "override instructions",
    ]

    private static var filePath: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/directive.md")
    }

    /// Check if content contains jailbreak patterns.
    static func containsJailbreakPattern(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return jailbreakPatterns.contains { lowered.contains($0) }
    }

    /// Validate instruction content before saving.
    private static func validateInstructions(_ text: String) -> ToolResult? {
        if text.count > maxInstructionLength {
            return .error(
                "Instructions too long (\(text.count) chars). Maximum is \(maxInstructionLength) characters."
            )
        }
        if containsJailbreakPattern(text) {
            return .error(
                "Instructions contain safety-override patterns and cannot be saved. "
                    + "Custom instructions are for style preferences only."
            )
        }
        return nil
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "adjust_setting":
            guard let key = input["key"] as? String else {
                return .error("Missing required parameter: key")
            }
            guard let spec = Self.adjustableKeys[key] else {
                return .error(
                    "Unknown setting: \(key). Adjustable: \(Self.adjustableKeys.keys.sorted().joined(separator: ", "))"
                )
            }
            guard let value = input["value"] else {
                return .error("Missing required parameter: value")
            }
            if let err = spec.validate(value) {
                return .error(err)
            }
            let coerced = spec.coerce(value)
            await MainActor.run { Self.configPatcher?(key, coerced) }
            return .success("Updated \(key) to \(coerced). The change is live.")

        case "get_settings":
            let currentConfig = FaeConfig.load()
            return .success(Self.formatCurrentSettings(currentConfig))

        case "get_directive", "get_instructions":
            let current = Self.readInstructions()
            if current.isEmpty {
                return .success("No directive set. Using default personality.")
            }
            return .success(current)

        case "set_directive", "set_instructions":
            guard let value = input["value"] as? String else {
                return .error("Missing required parameter: value")
            }
            if let rejection = Self.validateInstructions(value) {
                return rejection
            }
            Self.writeInstructions(value)
            return .success("Directive updated. Changes take effect on next response.")

        case "append_directive", "append_instructions":
            guard let value = input["value"] as? String else {
                return .error("Missing required parameter: value")
            }
            let current = Self.readInstructions()
            let updated = current.isEmpty ? value : current + "\n" + value
            if let rejection = Self.validateInstructions(updated) {
                return rejection
            }
            Self.writeInstructions(updated)
            return .success("Appended to directive. Changes take effect on next response.")

        case "clear_directive", "clear_instructions":
            Self.writeInstructions("")
            return .success("Directive cleared. Reverting to default personality.")

        default:
            return .error(
                "Unknown action: \(action). Use: adjust_setting, get_settings, get_directive, set_directive, append_directive, clear_directive"
            )
        }
    }

    static func readInstructions() -> String {
        guard let data = try? Data(contentsOf: filePath),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeInstructions(_ text: String) {
        let dir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: filePath, atomically: true, encoding: .utf8)
    }

    /// Format current adjustable settings for the LLM.
    private static func formatCurrentSettings(_ config: FaeConfig) -> String {
        var lines: [String] = ["Current settings:"]
        lines.append("  tts.speed = \(config.tts.speed) — Speaking speed (0.8=slow, 1.0=normal, 1.4=fast)")
        lines.append("  tts.voice_identity_lock = \(config.tts.voiceIdentityLock) — Force canonical bundled fae.wav")
        lines.append("  llm.temperature = \(config.llm.temperature) — Creativity (0.3=precise, 1.0=creative)")
        lines.append("  llm.thinking_enabled = \(config.llm.thinkingEnabled) — Extended reasoning")
        lines.append("  barge_in.enabled = \(config.bargeIn.enabled) — Allow interruption")
        lines.append(
            "  conversation.require_direct_address = \(config.conversation.requireDirectAddress)"
                + " — Name-gated responses"
        )
        lines.append(
            "  conversation.direct_address_followup_s = \(config.conversation.directAddressFollowupS)"
                + " — Follow-up window (seconds)"
        )
        lines.append("  tool_mode = \(config.toolMode) — Maximum tool authority level")
        lines.append("  vision.enabled = \(config.vision.enabled) — Enable on-device vision tools")
        lines.append("  vision.model_preset = \(config.vision.modelPreset) — Vision model preset")
        lines.append("  awareness.enabled = \(config.awareness.enabled) — Proactive orchestration master toggle")
        lines.append("  awareness.consent_granted = \(config.awareness.consentGrantedAt != nil) — Explicit consent for camera/screen awareness")
        lines.append("  awareness.camera_enabled = \(config.awareness.cameraEnabled) — Camera awareness")
        lines.append("  awareness.screen_enabled = \(config.awareness.screenEnabled) — Screen awareness")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Web Search Tool

/// Searches the web using DuckDuckGo's HTML endpoint.
///
/// Ported from `fae-search/src/engines/duckduckgo.rs` — uses the no-JS
/// HTML-only endpoint (`https://html.duckduckgo.com/html/`), parses
/// `.result__a` titles and `.result__snippet` snippets, and unwraps
/// DDG redirect URLs.
struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web using multiple engines (DuckDuckGo, Brave, Google, Bing). Results are deduplicated and ranked across engines for quality."
    let parametersSchema = #"{"query": "string (required)", "max_results": "integer (optional, default 10)"}"#
    let requiresApproval = false
    let example = #"<tool_call>{"name":"web_search","arguments":{"query":"latest Swift concurrency features"}}</tool_call>"#

    private static let maxOutputChars = 100_000
    private static let orchestrator = SearchOrchestrator()

    /// Categorize a URL's domain for quality indication.
    private static func domainCategory(for urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased()
        else { return "" }

        // Strip www. prefix for matching.
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        // News domains.
        let newsDomains: Set<String> = [
            "reuters.com", "apnews.com", "bbc.com", "bbc.co.uk", "nytimes.com",
            "theguardian.com", "washingtonpost.com", "cnn.com", "npr.org",
            "arstechnica.com", "theverge.com", "techcrunch.com", "wired.com",
            "bloomberg.com", "ft.com", "economist.com", "9to5mac.com",
            "macrumors.com", "engadget.com",
        ]
        if newsDomains.contains(domain) { return "[News]" }

        // Reference / documentation.
        let refDomains: Set<String> = [
            "wikipedia.org", "en.wikipedia.org", "developer.apple.com",
            "docs.swift.org", "docs.python.org", "docs.rs", "doc.rust-lang.org",
            "developer.mozilla.org", "w3.org", "rfc-editor.org",
        ]
        if refDomains.contains(domain) { return "[Reference]" }

        // Code / developer.
        let codeDomains: Set<String> = [
            "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com",
            "stackexchange.com", "npmjs.com", "pypi.org", "crates.io",
            "pkg.go.dev", "swiftpackageindex.com", "cocoapods.org",
        ]
        if codeDomains.contains(domain) { return "[Code]" }

        // Forums / community.
        let forumDomains: Set<String> = [
            "reddit.com", "old.reddit.com", "news.ycombinator.com",
            "lobste.rs", "discourse.org", "forums.swift.org",
            "discuss.python.org", "quora.com",
        ]
        if forumDomains.contains(domain) { return "[Forum]" }

        // Academic.
        let academicDomains: Set<String> = [
            "arxiv.org", "scholar.google.com", "ieee.org", "acm.org",
            "nature.com", "science.org", "pnas.org", "researchgate.net",
        ]
        if academicDomains.contains(domain) { return "[Academic]" }

        // Social media.
        let socialDomains: Set<String> = [
            "twitter.com", "x.com", "mastodon.social", "linkedin.com",
            "facebook.com", "youtube.com", "medium.com", "substack.com",
        ]
        if socialDomains.contains(domain) { return "[Social]" }

        return ""
    }

    /// Extract the display domain from a URL string.
    private static func displayDomain(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return domain
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let query = input["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error("Missing required parameter: query")
        }

        let maxResults = (input["max_results"] as? Int) ?? 10
        var config = SearchConfig.default
        config.maxResults = maxResults

        do {
            let results = try await Self.orchestrator.search(query: query, config: config)
            if results.isEmpty {
                return .success("No results found for \"\(query)\".")
            }

            var output = "## Search Results for \"\(query)\"\n\n"
            for (i, result) in results.enumerated() {
                let category = Self.domainCategory(for: result.url)
                let domain = Self.displayDomain(for: result.url)
                let tag = category.isEmpty ? domain : "\(category) \(domain)"
                output += "\(i + 1). **\(result.title)** (\(tag))\n   URL: \(result.url)\n   \(result.snippet)\n\n"
            }

            if output.count > Self.maxOutputChars {
                return .success(String(output.prefix(Self.maxOutputChars)) + "\n[truncated]")
            }
            return .success(output)
        } catch {
            return .error("Web search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Fetch URL Tool

/// Fetches a web page and extracts readable text content.
///
/// Uses ContentExtractor to strip boilerplate (scripts, styles, nav, footer,
/// header, aside), extract main content, and return clean text with word count.
struct FetchURLTool: Tool {
    let name = "fetch_url"
    let description = "Fetch a web page and extract its readable text content."
    let parametersSchema = #"{"url": "string (required, must start with http:// or https://)"}"#
    let requiresApproval = false
    let example = #"<tool_call>{"name":"fetch_url","arguments":{"url":"https://example.com/article"}}</tool_call>"#

    private static let orchestrator = SearchOrchestrator()

    /// Check whether a URL is blocked by network target policy.
    static func blockedReason(for urlString: String) -> String? {
        NetworkTargetPolicy.blockedReason(urlString: urlString)
    }

    /// Backward-compatible metadata-only checker retained for older tests.
    static func isCloudMetadataBlocked(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased()
        else { return false }
        return host == "169.254.169.254" || host == "metadata.google.internal"
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let urlString = input["url"] as? String,
              !urlString.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .error("Missing required parameter: url")
        }

        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return .error("URL must start with http:// or https://")
        }

        if let blockedReason = Self.blockedReason(for: urlString) {
            return .error(blockedReason)
        }

        do {
            let page = try await Self.orchestrator.fetchPageContent(urlString: urlString)

            if page.text.isEmpty {
                return .success("No extractable text content at \(urlString)")
            }

            var output = "## Page Content: \(page.title)\n\nURL: \(page.url)\nWords: \(page.wordCount)\n\n\(page.text)"
            if output.count > ContentExtractor.maxChars {
                output = String(output.prefix(ContentExtractor.maxChars)) + "\n\n[Content truncated]"
            }
            return .success(output)
        } catch {
            return .error("Fetch failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - InputRequestTool

/// Allows the LLM to request text input from the user (API keys, passwords, etc.).
///
/// Use this when you need information that shouldn't be stored in context or memory:
/// - API keys and secrets
/// - Passwords
/// - One-time codes
/// - Sensitive personal information
///
/// Routes through `InputRequestBridge.shared` which manages the NotificationCenter
/// bridge to the UI overlay and suspends until the user responds or 120s elapses.
struct InputRequestTool: Tool {
    let name = "input_request"
    let description = """
        Request text input from the user via a floating card near the orb. \
        Use for API keys, passwords, URLs, SSH keys, config snippets, or any \
        information the user needs to provide. Customise the card title, prompt, \
        placeholder, and input style to match the conversation context. \
        Returns the entered text, or a cancellation notice if dismissed.
        """
    let parametersSchema = #"{"prompt": "string (required) — what you need and why", "title": "string (optional) — card header, e.g. 'API Key Required'", "placeholder": "string (optional) — hint text inside the field", "secure": "boolean (optional) — true for passwords/keys (dots instead of text)", "multiline": "boolean (optional) — true for multi-line input (SSH keys, config, code)", "min_length": "integer (optional)", "regex": "string (optional)", "store_key": "string (optional) — persist secure input to keychain under this key", "return_to_model": "boolean (optional) — when secure=true, defaults to false so raw secrets stay out of model context"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"input_request","arguments":{"prompt":"Enter your OpenAI API key to continue","title":"API Key Required","placeholder":"sk-...","secure":true,"store_key":"channels.discord.bot_token"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        let prompt = input["prompt"] as? String ?? "Please enter a value"
        let title = input["title"] as? String
        let placeholder = input["placeholder"] as? String ?? ""
        let secure = input["secure"] as? Bool ?? false
        let multiline = input["multiline"] as? Bool ?? false
        let minLength = input["min_length"] as? Int ?? 0
        let regexPattern = input["regex"] as? String
        let storeKey = input["store_key"] as? String
        let returnToModel = input["return_to_model"] as? Bool ?? !secure

        let text = await InputRequestBridge.shared.request(
            prompt: prompt,
            title: title,
            placeholder: placeholder,
            isSecure: secure,
            isMultiline: multiline
        )

        guard let value = text, !value.isEmpty else {
            return .success("[user cancelled input]")
        }

        if value.count < minLength {
            return .error("Input is shorter than required minimum length (\(minLength)).")
        }

        if let regexPattern, !regexPattern.isEmpty,
           let regex = try? NSRegularExpression(pattern: regexPattern)
        {
            let range = NSRange(value.startIndex..., in: value)
            if regex.firstMatch(in: value, options: [], range: range) == nil {
                return .error("Input did not match required format.")
            }
        }

        if let storeKey, !storeKey.isEmpty {
            guard Self.isSafeKeychainKey(storeKey) else {
                return .error("store_key contains invalid characters.")
            }
            do {
                try CredentialManager.store(key: storeKey, value: value)
                return .success("[input stored securely in keychain: \(storeKey)]")
            } catch {
                return .error("Failed to store secure input: \(error.localizedDescription)")
            }
        }

        if secure && !returnToModel {
            return .success("[secure input captured locally and withheld from model context]")
        }

        return .success(value)
    }

    private static func isSafeKeychainKey(_ key: String) -> Bool {
        let pattern = "^[A-Za-z0-9._-]{3,128}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(key.startIndex..., in: key)
        return regex.firstMatch(in: key, options: [], range: range) != nil
    }
}

// MARK: - InputRequestBridge

/// NotificationCenter bridge that posts input requests to the UI and suspends
/// the caller until the user responds.
///
/// Acts as a coordination point between `InputRequestTool` (called by the LLM
/// during tool execution) and `ApprovalOverlayController` (the SwiftUI overlay
/// that shows the input card and posts responses back).
///
/// `PipelineCoordinator.inputRequired()` also uses this bridge so that both
/// entry points share the same continuation table and observer.
actor InputRequestBridge {
    struct FormField: Sendable {
        let id: String
        let label: String
        let placeholder: String
        let isSecure: Bool
        let required: Bool
        let minLength: Int?
        let maxLength: Int?
        let regex: String?
        let allowedValues: [String]?
        let mustBeHttps: Bool
    }

    static let shared = InputRequestBridge()

    private var textContinuations: [String: CheckedContinuation<String?, Never>] = [:]
    private var formContinuations: [String: CheckedContinuation<[String: String]?, Never>] = [:]
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .faeInputResponse,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let requestId = notification.userInfo?["request_id"] as? String ?? ""
            let text = notification.userInfo?["text"] as? String ?? ""
            let formValues = Self.parseFormValues(notification.userInfo)
            Task { await self.resolve(requestId: requestId, text: text, formValues: formValues) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Post a single-field input request to the UI and suspend until the user responds.
    ///
    /// - Returns: The user's text, or nil if cancelled or timed out.
    func request(
        prompt: String,
        title: String? = nil,
        placeholder: String = "",
        isSecure: Bool = false,
        isMultiline: Bool = false
    ) async -> String? {
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            textContinuations[requestId] = continuation

            var info: [String: Any] = [
                "request_id": requestId,
                "prompt": prompt,
                "placeholder": placeholder,
                "is_secure": isSecure,
                "is_multiline": isMultiline,
                "mode": "text",
            ]
            if let title { info["title"] = title }

            NotificationCenter.default.post(
                name: .faeInputRequired,
                object: nil,
                userInfo: info
            )

            Task { [requestId] in
                try? await Task.sleep(for: .seconds(120))
                await self.resolveWithTimeout(requestId: requestId)
            }
        }
    }

    /// Post a multi-field form request to the UI and suspend until submit/cancel.
    ///
    /// - Returns: Field-value map, or nil if cancelled/timed out.
    func requestForm(
        title: String,
        prompt: String,
        fields: [FormField]
    ) async -> [String: String]? {
        guard !fields.isEmpty else { return nil }

        let requestId = UUID().uuidString
        let fieldPayload: [[String: Any]] = fields.map {
            var payload: [String: Any] = [
                "id": $0.id,
                "label": $0.label,
                "placeholder": $0.placeholder,
                "is_secure": $0.isSecure,
                "required": $0.required,
                "must_be_https": $0.mustBeHttps,
            ]
            if let minLength = $0.minLength { payload["min_length"] = minLength }
            if let maxLength = $0.maxLength { payload["max_length"] = maxLength }
            if let regex = $0.regex, !regex.isEmpty { payload["regex"] = regex }
            if let allowedValues = $0.allowedValues, !allowedValues.isEmpty {
                payload["allowed_values"] = allowedValues
            }
            return payload
        }

        return await withCheckedContinuation { continuation in
            formContinuations[requestId] = continuation

            NotificationCenter.default.post(
                name: .faeInputRequired,
                object: nil,
                userInfo: [
                    "request_id": requestId,
                    "mode": "form",
                    "title": title,
                    "prompt": prompt,
                    "fields": fieldPayload,
                ]
            )

            Task { [requestId] in
                try? await Task.sleep(for: .seconds(120))
                await self.resolveWithTimeout(requestId: requestId)
            }
        }
    }

    private static func parseFormValues(_ userInfo: [AnyHashable: Any]?) -> [String: String]? {
        guard let raw = userInfo?["form_values"] else { return nil }

        if let typed = raw as? [String: String] {
            return typed
                .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.value.isEmpty }
        }

        if let anyMap = raw as? [String: Any] {
            var mapped: [String: String] = [:]
            for (key, value) in anyMap {
                let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    mapped[key] = text
                }
            }
            return mapped.isEmpty ? nil : mapped
        }

        return nil
    }

    private func resolve(requestId: String, text: String, formValues: [String: String]?) {
        if let continuation = formContinuations.removeValue(forKey: requestId) {
            continuation.resume(returning: formValues)
            return
        }

        if let continuation = textContinuations.removeValue(forKey: requestId) {
            continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text)
        }
    }

    private func resolveWithTimeout(requestId: String) async {
        let textContinuation = textContinuations.removeValue(forKey: requestId)
        let formContinuation = formContinuations.removeValue(forKey: requestId)
        guard textContinuation != nil || formContinuation != nil else { return }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .faeInputResponse,
                object: nil,
                userInfo: ["request_id": requestId, "text": ""]
            )
        }

        textContinuation?.resume(returning: nil)
        formContinuation?.resume(returning: nil)
    }
}
