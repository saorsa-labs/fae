import Foundation
import MCP
@preconcurrency import System

/// Manages MCP client connections to plugin-provided MCP servers.
///
/// Each plugin with a `.mcp.json` gets one or more MCP `Client` connections.
/// The bridge:
/// 1. Parses `.mcp.json` from installed plugins
/// 2. Spawns stdio servers as subprocesses or connects to HTTP servers
/// 3. Lists available tools from each server
/// 4. Forwards tool calls from `MCPToolProxy` to the appropriate MCP client
///
/// All connections are managed with lifecycle (start/stop) and automatic cleanup.
actor MCPBridge {

    /// Active MCP connections keyed by server name.
    private var connections: [String: MCPConnection] = [:]

    /// Tools discovered from all connected MCP servers.
    private var discoveredTools: [String: MCP.Tool] = [:]

    /// Map from Fae tool name → (serverName, mcpToolName).
    private var toolRouting: [String: (serverName: String, mcpToolName: String)] = [:]

    /// Running subprocess processes (for stdio servers).
    private var serverProcesses: [String: Process] = [:]

    /// Wrapper holding an MCP Client and its transport.
    private struct MCPConnection: Sendable {
        let client: MCP.Client
        let serverName: String
        let pluginId: String
    }

    // MARK: - Lifecycle

    /// Start MCP servers for all enabled plugins that have `.mcp.json`.
    func startServers(for plugins: [InstalledPlugin]) async {
        for plugin in plugins where plugin.isEnabled {
            guard let config = MCPServerConfig.load(from: plugin.directoryURL) else {
                continue
            }

            for (serverName, entry) in config.servers {
                await startServer(
                    serverName: serverName,
                    entry: entry,
                    pluginId: plugin.id
                )
            }
        }
    }

    /// Stop all MCP connections and kill server processes.
    func stopAll() async {
        for (name, connection) in connections {
            await connection.client.disconnect()
            NSLog("MCPBridge: disconnected from '%@'", name)
        }
        connections.removeAll()

        for (name, process) in serverProcesses {
            if process.isRunning {
                process.terminate()
                NSLog("MCPBridge: terminated server process '%@'", name)
            }
        }
        serverProcesses.removeAll()
        discoveredTools.removeAll()
        toolRouting.removeAll()
    }

    /// Stop servers belonging to a specific plugin.
    func stopServers(for pluginId: String) async {
        let serversToStop = connections.filter { $0.value.pluginId == pluginId }

        for (name, connection) in serversToStop {
            await connection.client.disconnect()
            connections.removeValue(forKey: name)

            if let process = serverProcesses.removeValue(forKey: name), process.isRunning {
                process.terminate()
            }

            // Remove tools from this server.
            let toolsToRemove = toolRouting.filter { $0.value.serverName == name }
            for key in toolsToRemove.keys {
                toolRouting.removeValue(forKey: key)
            }

            NSLog("MCPBridge: stopped server '%@' for plugin '%@'", name, pluginId)
        }
    }

    // MARK: - Tool Discovery

    /// Get all MCP tool proxies for registration in ToolRegistry.
    func allToolProxies() -> [MCPToolProxy] {
        toolRouting.compactMap { (faeToolName, routing) -> MCPToolProxy? in
            guard let mcpTool = discoveredTools[faeToolName] else { return nil }
            return MCPToolProxy(mcpTool: mcpTool, serverName: routing.serverName, bridge: self)
        }
    }

    /// List all discovered MCP tool names.
    func toolNames() -> [String] {
        Array(toolRouting.keys).sorted()
    }

    /// Count tools belonging to servers started for a specific plugin.
    func toolCount(for pluginId: String) -> Int {
        let pluginServers = Set(
            connections.filter { $0.value.pluginId == pluginId }.keys
        )
        return toolRouting.values.filter { pluginServers.contains($0.serverName) }.count
    }

    // MARK: - Tool Execution

    /// Call an MCP tool by server name and tool name.
    ///
    /// Called by `MCPToolProxy.execute()`.
    func callTool(
        serverName: String,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> String {
        guard let connection = connections[serverName] else {
            throw MCPBridgeError.serverNotConnected(serverName)
        }

        // Convert [String: Any] to MCP [String: Value].
        let mcpArgs = arguments.compactMapValues { anyToValue($0) }

        let (content, isError) = try await connection.client.callTool(
            name: toolName,
            arguments: mcpArgs
        )

        // Extract text content from the result.
        return formatToolContent(content, isError: isError)
    }

    // MARK: - Private — Server Startup

    private func startServer(
        serverName: String,
        entry: MCPServerEntry,
        pluginId: String
    ) async {
        do {
            switch entry {
            case .stdio(let command, let args, let env):
                try await startStdioServer(
                    serverName: serverName,
                    command: command,
                    args: args,
                    env: env,
                    pluginId: pluginId
                )

            case .http(let url, _):
                try await startHTTPServer(
                    serverName: serverName,
                    url: url,
                    pluginId: pluginId
                )
            }
        } catch {
            NSLog(
                "MCPBridge: failed to start server '%@' for plugin '%@': %@",
                serverName,
                pluginId,
                error.localizedDescription
            )
        }
    }

    private func startStdioServer(
        serverName: String,
        command: String,
        args: [String],
        env: [String: String]?,
        pluginId: String
    ) async throws {
        // Spawn the server process.
        let process = Process()

        // Resolve command path.
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
        } else {
            guard let resolved = resolveExecutable(command) else {
                throw MCPBridgeError.executableNotFound(command)
            }
            process.executableURL = resolved
        }

        process.arguments = args

        if let env {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        serverProcesses[serverName] = process

        // Create MCP client with stdio transport.
        let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(
            input: inputFD,
            output: outputFD
        )

        let client = Client(name: "Fae", version: "1.0.0")
        _ = try await client.connect(transport: transport)

        let connection = MCPConnection(
            client: client,
            serverName: serverName,
            pluginId: pluginId
        )
        connections[serverName] = connection

        // Discover tools.
        try await discoverServerTools(serverName: serverName, client: client)

        NSLog(
            "MCPBridge: connected to stdio server '%@' (%d tools)",
            serverName,
            toolRouting.filter { $0.value.serverName == serverName }.count
        )
    }

    private func startHTTPServer(
        serverName: String,
        url: URL,
        pluginId: String
    ) async throws {
        let transport = HTTPClientTransport(endpoint: url)

        let client = Client(name: "Fae", version: "1.0.0")
        _ = try await client.connect(transport: transport)

        let connection = MCPConnection(
            client: client,
            serverName: serverName,
            pluginId: pluginId
        )
        connections[serverName] = connection

        // Discover tools.
        try await discoverServerTools(serverName: serverName, client: client)

        NSLog(
            "MCPBridge: connected to HTTP server '%@' at %@ (%d tools)",
            serverName,
            url.absoluteString,
            toolRouting.filter { $0.value.serverName == serverName }.count
        )
    }

    private func discoverServerTools(serverName: String, client: Client) async throws {
        let (tools, _) = try await client.listTools()

        for tool in tools {
            let faeToolName = "mcp_\(serverName)_\(tool.name)"
            discoveredTools[faeToolName] = tool
            toolRouting[faeToolName] = (serverName: serverName, mcpToolName: tool.name)
        }
    }

    // MARK: - Private — Conversion

    /// Convert Any to MCP Value.
    private func anyToValue(_ value: Any) -> MCP.Value? {
        if let s = value as? String { return .string(s) }
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let b = value as? Bool { return .bool(b) }
        if let arr = value as? [Any] {
            return .array(arr.compactMap { anyToValue($0) })
        }
        if let dict = value as? [String: Any] {
            return .object(dict.compactMapValues { anyToValue($0) })
        }
        return nil
    }

    /// Format MCP tool result content to a string for the LLM.
    ///
    /// Extracts text content from `Tool.Content` items. Non-text content
    /// (images, audio, resources) are represented as placeholder strings.
    private func formatToolContent(_ content: [MCP.Tool.Content], isError: Bool?) -> String {
        let encoder = JSONEncoder()
        var parts: [String] = []

        for item in content {
            // Tool.Content is an enum — extract text where possible.
            // Use JSON round-trip for API stability across SDK versions.
            if let data = try? encoder.encode(item),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                if let text = dict["text"] as? String {
                    parts.append(text)
                } else if let uri = dict["uri"] as? String {
                    parts.append("[Resource: \(uri)]")
                } else {
                    parts.append("[Non-text content]")
                }
            }
        }

        if let isError, isError {
            return "Error: " + parts.joined(separator: "\n")
        }

        return parts.joined(separator: "\n")
    }

    /// Resolve an executable name to a full path.
    private nonisolated func resolveExecutable(_ name: String) -> URL? {
        PluginExecutableResolver.resolve(name)
    }
}

/// Errors from MCPBridge operations.
enum MCPBridgeError: LocalizedError, Sendable {
    case serverNotConnected(String)
    case executableNotFound(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverNotConnected(let name):
            return "MCP server '\(name)' is not connected"
        case .executableNotFound(let command):
            return "MCP server executable not found: \(command)"
        case .connectionFailed(let reason):
            return "MCP connection failed: \(reason)"
        }
    }
}
