import Foundation

// MARK: - Read Tool

struct ReadTool: Tool {
    let name = "read"
    let description = "Read the contents of a file at the given path."
    let parametersSchema = #"{"path": "string (required)"}"#
    let requiresApproval = false

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

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String
        else {
            return .error("Missing required parameters: path, content")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            let dir = (expanded as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return .success("Written \(content.count) bytes to \(path)")
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Edit Tool

struct EditTool: Tool {
    let name = "edit"
    let description = "Replace a string in a file. The old_string must match exactly."
    let parametersSchema = #"{"path": "string", "old_string": "string", "new_string": "string"}"#
    let requiresApproval = true

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let path = input["path"] as? String,
              let oldString = input["old_string"] as? String,
              let newString = input["new_string"] as? String
        else {
            return .error("Missing required parameters: path, old_string, new_string")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            var content = try String(contentsOfFile: expanded, encoding: .utf8)
            guard content.contains(oldString) else {
                return .error("old_string not found in file")
            }
            content = content.replacingOccurrences(of: oldString, with: newString)
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return .success("Replaced in \(path)")
        } catch {
            return .error("Edit failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Bash Tool

struct BashTool: Tool {
    let name = "bash"
    let description = "Execute a shell command and return its output."
    let parametersSchema = #"{"command": "string (required)"}"#
    let requiresApproval = true

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let command = input["command"] as? String else {
            return .error("Missing required parameter: command")
        }

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

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            let output = outStr + (errStr.isEmpty ? "" : "\nSTDERR: \(errStr)")
            let truncated = output.count > 20_000
                ? String(output.prefix(20_000)) + "\n[truncated]"
                : output

            if process.terminationStatus != 0 {
                return .error("Exit code \(process.terminationStatus)\n\(truncated)")
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
        Modify Fae's own behavior, personality style, or preferences. \
        Use this when the user asks you to change how you communicate \
        (e.g., "be more cheerful", "less chatty", "speak more formally"). \
        Actions: get_instructions, set_instructions, append_instructions, clear_instructions.
        """
    let parametersSchema = #"""
        {"action": "string (required: get_instructions|set_instructions|append_instructions|clear_instructions)", "value": "string (required for set/append)"}
        """#
    let requiresApproval = false

    private static var filePath: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("fae/custom_instructions.txt")
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
            Self.writeInstructions(value)
            return .success("Custom instructions updated. Changes take effect on next response.")

        case "append_instructions":
            guard let value = input["value"] as? String else {
                return .error("Missing required parameter: value")
            }
            let current = Self.readInstructions()
            let updated = current.isEmpty ? value : current + "\n" + value
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

    private static let maxOutputChars = 100_000
    private static let orchestrator = SearchOrchestrator()

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
                output += "\(i + 1). **\(result.title)**\n   URL: \(result.url)\n   \(result.snippet)\n\n"
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

    private static let orchestrator = SearchOrchestrator()

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let urlString = input["url"] as? String,
              !urlString.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .error("Missing required parameter: url")
        }

        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return .error("URL must start with http:// or https://")
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
