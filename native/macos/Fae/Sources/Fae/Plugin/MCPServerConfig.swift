import Foundation

/// Parsed `.mcp.json` configuration from a Claude Code plugin.
///
/// Supports two server types:
/// - **stdio**: local subprocess (`command` + `args`)
/// - **http**: remote HTTP server (`url` + optional OAuth)
///
/// Example `.mcp.json`:
/// ```json
/// {
///   "mcpServers": {
///     "imessage": {
///       "command": "bun",
///       "args": ["run", "--cwd", "${CLAUDE_PLUGIN_ROOT}", "start"]
///     },
///     "slack": {
///       "type": "http",
///       "url": "https://mcp.slack.com/mcp",
///       "oauth": { "clientId": "...", "callbackPort": 3118 }
///     }
///   }
/// }
/// ```
struct MCPServerConfig: Sendable {
    let servers: [String: MCPServerEntry]

    /// Parse an `.mcp.json` file from a plugin directory.
    ///
    /// Substitutes `${CLAUDE_PLUGIN_ROOT}` with the actual plugin path.
    static func load(from pluginDir: URL) -> MCPServerConfig? {
        let mcpFile = pluginDir.appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: mcpFile) else { return nil }

        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The .mcp.json can have either top-level keys or be wrapped in "mcpServers".
        let serversDict: [String: Any]
        if let wrapped = raw["mcpServers"] as? [String: Any] {
            serversDict = wrapped
        } else {
            serversDict = raw
        }

        let pluginPath = pluginDir.path
        var entries: [String: MCPServerEntry] = [:]

        for (name, value) in serversDict {
            guard let config = value as? [String: Any] else { continue }

            if let entry = parseServerEntry(config, pluginPath: pluginPath) {
                entries[name] = entry
            }
        }

        return entries.isEmpty ? nil : MCPServerConfig(servers: entries)
    }

    private static func parseServerEntry(
        _ config: [String: Any],
        pluginPath: String
    ) -> MCPServerEntry? {
        let serverType = (config["type"] as? String) ?? "stdio"

        switch serverType.lowercased() {
        case "http":
            guard let urlString = config["url"] as? String,
                  let url = URL(string: substitute(urlString, pluginPath: pluginPath))
            else {
                return nil
            }

            // Block localhost, private IPs, and metadata endpoints.
            let resolvedURL = substitute(urlString, pluginPath: pluginPath)
            if let reason = NetworkTargetPolicy.blockedReason(urlString: resolvedURL) {
                NSLog("MCPServerConfig: blocked HTTP server URL '%@': %@", resolvedURL, reason)
                return nil
            }

            var oauth: MCPOAuthConfig?
            if let oauthDict = config["oauth"] as? [String: Any],
               let clientId = oauthDict["clientId"] as? String
            {
                oauth = MCPOAuthConfig(
                    clientId: clientId,
                    callbackPort: oauthDict["callbackPort"] as? Int
                )
            }

            return .http(url: url, oauth: oauth)

        case "stdio":
            guard let command = config["command"] as? String else { return nil }
            let args = (config["args"] as? [String])?.map {
                substitute($0, pluginPath: pluginPath)
            } ?? []
            let env = (config["env"] as? [String: String])?.mapValues {
                substitute($0, pluginPath: pluginPath)
            }

            return .stdio(
                command: substitute(command, pluginPath: pluginPath),
                args: args,
                env: env
            )

        default:
            return nil
        }
    }

    /// Replace `${CLAUDE_PLUGIN_ROOT}` and `${FAE_PLUGIN_ROOT}` with the actual path.
    private static func substitute(_ value: String, pluginPath: String) -> String {
        PluginExecutableResolver.substitutePluginRoot(value, pluginPath: pluginPath)
    }
}

/// A single MCP server entry — either a local subprocess or a remote HTTP endpoint.
enum MCPServerEntry: Sendable {
    /// Local subprocess server — Fae spawns the process and communicates via stdio.
    case stdio(command: String, args: [String], env: [String: String]?)

    /// Remote HTTP server with optional OAuth.
    case http(url: URL, oauth: MCPOAuthConfig?)
}

/// OAuth configuration for HTTP MCP servers (e.g., Slack).
struct MCPOAuthConfig: Sendable {
    let clientId: String
    let callbackPort: Int?
}
