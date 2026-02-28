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

    private enum BashToolError: LocalizedError {
        case timedOut(Int)

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "Command timed out after \(seconds)s"
            }
        }
    }

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
            let (status, outData, errData) = try await runProcess(command: command, timeoutSeconds: 30)
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

    private func runProcess(command: String, timeoutSeconds: Int) async throws -> (Int32, Data, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        // Ensure user-installed tools (uv, homebrew, etc.) are in PATH.
        // macOS GUI apps inherit a minimal PATH that excludes ~/.local/bin.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(existing)"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let outputTask = Task<(Data, Data), Never> {
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return (outData, errData)
        }

        do {
            let status = try await waitForExit(process: process, timeoutSeconds: timeoutSeconds)
            let (outData, errData) = await outputTask.value
            return (status, outData, errData)
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = await outputTask.value
            throw error
        }
    }

    private func waitForExit(process: Process, timeoutSeconds: Int) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            if Date() >= deadline {
                // Kill entire process group, not just the parent.
                let pid = process.processIdentifier
                kill(-pid, SIGTERM)
                // Give processes a moment to clean up, then force kill.
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    kill(-pid, SIGKILL)
                }
                throw BashToolError.timedOut(timeoutSeconds)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return process.terminationStatus
    }
}

// MARK: - Self Config Tool

struct SelfConfigTool: Tool {
    let name = "self_config"
    let description = """
        Modify Fae's own behavior, personality style, or preferences. \
        Use this when the user asks you to change how you communicate \
        (e.g., "be more cheerful", "less chatty", "speak more formally"). \
        Actions: get_instructions, set_instructions, append_instructions, clear_instructions.
        """
    let parametersSchema = #"""
        {"action": "string (required: get_instructions|set_instructions|append_instructions|clear_instructions)", "value": "string (required for set/append)"}
        """#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"self_config","arguments":{"action":"append_instructions","value":"Be more concise"}}</tool_call>"#

    /// Maximum character length for custom instructions.
    private static let maxInstructionLength = 2000

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
        return appSupport.appendingPathComponent("fae/custom_instructions.txt")
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
        case "get_instructions":
            let current = Self.readInstructions()
            if current.isEmpty {
                return .success("No custom instructions set. Using default personality.")
            }
            return .success(current)

        case "set_instructions":
            guard let value = input["value"] as? String else {
                return .error("Missing required parameter: value")
            }
            if let rejection = Self.validateInstructions(value) {
                return rejection
            }
            Self.writeInstructions(value)
            return .success("Custom instructions updated. Changes take effect on next response.")

        case "append_instructions":
            guard let value = input["value"] as? String else {
                return .error("Missing required parameter: value")
            }
            let current = Self.readInstructions()
            let updated = current.isEmpty ? value : current + "\n" + value
            if let rejection = Self.validateInstructions(updated) {
                return rejection
            }
            Self.writeInstructions(updated)
            return .success("Appended to custom instructions. Changes take effect on next response.")

        case "clear_instructions":
            Self.writeInstructions("")
            return .success("Custom instructions cleared. Reverting to default personality.")

        default:
            return .error("Unknown action: \(action). Use: get_instructions, set_instructions, append_instructions, clear_instructions")
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

// MARK: - Run Skill Tool

/// Run an installed Python skill by name.
struct RunSkillTool: Tool {
    let name = "run_skill"
    let description = "Run an installed Python skill by name. Use this instead of composing bash commands with skill paths."
    let parametersSchema = #"{"name": "string (required — skill name without .py)", "input": "string (optional — input text for the skill)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .medium
    let example = #"<tool_call>{"name":"run_skill","arguments":{"name":"weather_check","input":"London"}}</tool_call>"#

    private let skillManager = SkillManager()

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let skillName = input["name"] as? String,
              !skillName.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .error("Missing required parameter: name")
        }

        var skillInput: [String: Any] = SkillManager.audioContextForSkill()
        if let text = input["input"] as? String {
            skillInput["input"] = text
        }

        do {
            let output = try await skillManager.execute(skillName: skillName, input: skillInput)
            let truncated = output.count > 20_000
                ? String(output.prefix(20_000)) + "\n[truncated]"
                : output
            return .success(truncated)
        } catch {
            return .error("Skill execution failed: \(error.localizedDescription)")
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

    /// Cloud metadata endpoints that could leak credentials on cloud VMs.
    private static let blockedHosts: Set<String> = [
        "169.254.169.254",
        "metadata.google.internal",
    ]

    /// Check if a URL targets a cloud metadata endpoint.
    static func isCloudMetadataBlocked(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased()
        else { return false }
        return blockedHosts.contains(host)
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

        if Self.isCloudMetadataBlocked(urlString) {
            return .error("Access to cloud metadata endpoints is blocked for security.")
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
        Request text input from the user. Use for API keys, passwords, or any sensitive \
        information you need but shouldn't store. The user will see a secure input card \
        near the orb. Returns the entered text, or a cancellation notice if dismissed.
        """
    let parametersSchema = #"{"prompt": "string (required) — what you need and why", "placeholder": "string (optional)", "secure": "boolean (optional) — true for passwords/keys"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"input_request","arguments":{"prompt":"Enter your OpenAI API key to continue","placeholder":"sk-...","secure":true}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        let prompt = input["prompt"] as? String ?? "Please enter a value"
        let placeholder = input["placeholder"] as? String ?? ""
        let secure = input["secure"] as? Bool ?? false

        let text = await InputRequestBridge.shared.request(
            prompt: prompt,
            placeholder: placeholder,
            isSecure: secure
        )

        if let value = text, !value.isEmpty {
            return .success(value)
        } else {
            return .success("[user cancelled input]")
        }
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
    static let shared = InputRequestBridge()

    private var continuations: [String: CheckedContinuation<String?, Never>] = [:]
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
            Task { await self.resolve(requestId: requestId, text: text) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Post an input request to the UI and suspend until the user responds.
    ///
    /// - Returns: The user's text, or nil if cancelled or timed out.
    func request(prompt: String, placeholder: String, isSecure: Bool) async -> String? {
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            continuations[requestId] = continuation

            NotificationCenter.default.post(
                name: .faeInputRequired,
                object: nil,
                userInfo: [
                    "request_id": requestId,
                    "prompt": prompt,
                    "placeholder": placeholder,
                    "is_secure": isSecure,
                ]
            )

            Task { [requestId] in
                try? await Task.sleep(for: .seconds(120))
                // Dismiss the UI card by posting an empty response, then resume nil.
                await self.resolveWithTimeout(requestId: requestId)
            }
        }
    }

    private func resolve(requestId: String, text: String) {
        if let continuation = continuations.removeValue(forKey: requestId) {
            continuation.resume(returning: text.isEmpty ? nil : text)
        }
    }

    private func resolveWithTimeout(requestId: String) async {
        guard let continuation = continuations.removeValue(forKey: requestId) else { return }
        // Post an empty response so ApprovalOverlayController dismisses the card.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .faeInputResponse,
                object: nil,
                userInfo: ["request_id": requestId, "text": ""]
            )
        }
        continuation.resume(returning: nil)
    }
}
