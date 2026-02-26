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

// MARK: - Web Search Tool

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for information."
    let parametersSchema = #"{"query": "string (required)"}"#
    let requiresApproval = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let query = input["query"] as? String else {
            return .error("Missing required parameter: query")
        }
        // Stub — real implementation would use a search API
        return .success("Web search for '\(query)' — no search provider configured yet.")
    }
}

// MARK: - Fetch URL Tool

struct FetchURLTool: Tool {
    let name = "fetch_url"
    let description = "Fetch the content of a URL."
    let parametersSchema = #"{"url": "string (required)"}"#
    let requiresApproval = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let urlString = input["url"] as? String,
              let url = URL(string: urlString)
        else {
            return .error("Missing or invalid parameter: url")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "[binary data, \(data.count) bytes]"
            let truncated = body.count > 20_000
                ? String(body.prefix(20_000)) + "\n[truncated]"
                : body
            return .success("HTTP \(status)\n\(truncated)")
        } catch {
            return .error("Fetch failed: \(error.localizedDescription)")
        }
    }
}
