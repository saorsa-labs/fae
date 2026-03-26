import Foundation

/// Tool for managing Fae plugins — install, list, remove, enable, disable, update.
///
/// Plugins follow the Claude Code format (`.claude-plugin/plugin.json`).
/// Install from git URLs, local paths, or the official plugin registry.
///
/// Medium-risk: installs code from external sources, modifies `~/.fae-plugins/`.
struct PluginTool: Tool {
    let name = "plugin_manage"
    let description = """
        Manage Fae plugins (Claude Code compatible). Install from git repos, list installed, \
        remove, enable/disable, update, or show plugin details.
        """
    let parametersSchema = #"""
        {
            "action": "string (required: install|install_from_registry|list|remove|enable|disable|update|show)",
            "url": "string (required for install — git URL or local path)",
            "plugin_path": "string (optional for install — subdirectory path within a monorepo, e.g. 'plugins/slack' or 'external_plugins/linear')",
            "name": "string (required for remove/enable/disable/update/show, optional for install — override plugin name)",
            "ref": "string (optional for install — git branch/tag/commit)"
        }
        """#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .medium
    let example = #"""
        <tool_call>{"name":"plugin_manage","arguments":{"action":"install","url":"https://github.com/user/plugin.git"}}</tool_call>
        """#

    private let pluginManager: PluginManager

    init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "install":
            return await handleInstall(input: input)
        case "install_from_registry":
            return await handleInstallFromRegistry(input: input)
        case "list":
            return await handleList()
        case "remove":
            return await handleRemove(input: input)
        case "enable":
            return await handleEnable(input: input)
        case "disable":
            return await handleDisable(input: input)
        case "update":
            return await handleUpdate(input: input)
        case "show":
            return await handleShow(input: input)
        default:
            return .error(
                "Unknown action '\(action)'. Use: install, install_from_registry, list, remove, enable, disable, update, show"
            )
        }
    }

    // MARK: - Handlers

    private func handleInstall(input: [String: Any]) async -> ToolResult {
        guard let url = input["url"] as? String, !url.isEmpty else {
            return .error("Missing required parameter: url")
        }

        let nameOverride = input["name"] as? String
        let ref = input["ref"] as? String
        let pluginPath = input["plugin_path"] as? String

        do {
            let plugin: InstalledPlugin

            if let pluginPath, !pluginPath.isEmpty {
                // Monorepo install — clone whole repo, extract specific plugin.
                plugin = try await pluginManager.installFromMonorepo(
                    repoURL: url,
                    pluginPath: pluginPath,
                    name: nameOverride,
                    ref: ref
                )
            } else if url.hasPrefix("/") || url.hasPrefix("~") {
                // Local path.
                let expandedPath = NSString(string: url).expandingTildeInPath
                plugin = try await pluginManager.install(
                    from: .local(path: expandedPath),
                    name: nameOverride
                )
            } else {
                // Git URL.
                plugin = try await pluginManager.install(
                    from: .git(url: url, ref: ref),
                    name: nameOverride
                )
            }

            return .success(formatPluginSummary(plugin, action: "Installed"))
        } catch {
            return .error("Install failed: \(error.localizedDescription)")
        }
    }

    private func handleInstallFromRegistry(input: [String: Any]) async -> ToolResult {
        guard let pluginName = input["name"] as? String, !pluginName.isEmpty else {
            return .error("Missing required parameter: name (plugin name from the registry)")
        }

        let ref = input["ref"] as? String
        let registryURL = "https://github.com/anthropics/claude-plugins-official.git"

        // Try both plugin directories in the official repo.
        let searchPaths = [
            "plugins/\(pluginName)",
            "external_plugins/\(pluginName)",
        ]

        for path in searchPaths {
            do {
                let plugin = try await pluginManager.installFromMonorepo(
                    repoURL: registryURL,
                    pluginPath: path,
                    name: pluginName,
                    ref: ref
                )
                return .success(formatPluginSummary(plugin, action: "Installed from registry"))
            } catch let error as PluginError {
                if case .alreadyInstalled = error {
                    return .error(error.localizedDescription)
                }
                // Try next path.
                continue
            } catch {
                continue
            }
        }

        return .error(
            "Plugin '\(pluginName)' not found in the official registry. "
            + "Try install with a direct git URL instead."
        )
    }

    private func handleList() async -> ToolResult {
        let plugins = await pluginManager.listPlugins()
        if plugins.isEmpty {
            return .success(
                "No plugins installed. Install with:\n"
                + "- plugin_manage install url=<git-url>\n"
                + "- plugin_manage install_from_registry name=<plugin-name>"
            )
        }

        var lines: [String] = ["Installed plugins (\(plugins.count)):"]
        for plugin in plugins {
            let status = plugin.isEnabled ? "enabled" : "disabled"
            let skillCount = plugin.skills.count + plugin.agents.count
            let version = plugin.manifest.version.map { " v\($0)" } ?? ""
            lines.append(
                "  - \(plugin.id)\(version) [\(status)] — \(plugin.manifest.description) "
                + "(\(skillCount) skills)"
            )
        }

        return .success(lines.joined(separator: "\n"))
    }

    private func handleRemove(input: [String: Any]) async -> ToolResult {
        guard let pluginName = input["name"] as? String, !pluginName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        do {
            try await pluginManager.remove(pluginId: pluginName)
            return .success("Removed plugin '\(pluginName)'.")
        } catch {
            return .error("Remove failed: \(error.localizedDescription)")
        }
    }

    private func handleEnable(input: [String: Any]) async -> ToolResult {
        guard let pluginName = input["name"] as? String, !pluginName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        do {
            try await pluginManager.enable(pluginId: pluginName)
            return .success("Enabled plugin '\(pluginName)'.")
        } catch {
            return .error("Enable failed: \(error.localizedDescription)")
        }
    }

    private func handleDisable(input: [String: Any]) async -> ToolResult {
        guard let pluginName = input["name"] as? String, !pluginName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        do {
            try await pluginManager.disable(pluginId: pluginName)
            return .success("Disabled plugin '\(pluginName)'. Skills from this plugin are no longer available.")
        } catch {
            return .error("Disable failed: \(error.localizedDescription)")
        }
    }

    private func handleUpdate(input: [String: Any]) async -> ToolResult {
        guard let pluginName = input["name"] as? String, !pluginName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        do {
            let plugin = try await pluginManager.update(pluginId: pluginName)
            return .success(formatPluginSummary(plugin, action: "Updated"))
        } catch {
            return .error("Update failed: \(error.localizedDescription)")
        }
    }

    private func handleShow(input: [String: Any]) async -> ToolResult {
        guard let pluginName = input["name"] as? String, !pluginName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        guard let plugin = await pluginManager.plugin(named: pluginName) else {
            return .error("Plugin '\(pluginName)' not found.")
        }

        var sections: [String] = [
            "Plugin: \(plugin.manifest.name)",
            "Description: \(plugin.manifest.description)",
            "Status: \(plugin.isEnabled ? "enabled" : "disabled")",
            "Location: \(plugin.directoryURL.path)",
        ]

        if let version = plugin.manifest.version {
            sections.append("Version: \(version)")
        }
        if let author = plugin.manifest.author {
            sections.append("Author: \(author.name)\(author.email.map { " <\($0)>" } ?? "")")
        }
        if let keywords = plugin.manifest.keywords, !keywords.isEmpty {
            sections.append("Keywords: \(keywords.joined(separator: ", "))")
        }

        if !plugin.skills.isEmpty {
            sections.append("\nSkills (\(plugin.skills.count)):")
            for skill in plugin.skills {
                let typeTag = skill.metadata.type == .executable ? " [executable]" : ""
                sections.append("  - \(skill.name): \(skill.metadata.description)\(typeTag)")
            }
        }

        if !plugin.agents.isEmpty {
            sections.append("\nAgents (\(plugin.agents.count)):")
            for agent in plugin.agents {
                sections.append("  - \(agent.name): \(agent.metadata.description)")
            }
        }

        // Check for MCP config.
        let mcpConfig = plugin.directoryURL.appendingPathComponent(".mcp.json")
        if FileManager.default.fileExists(atPath: mcpConfig.path) {
            sections.append("\nMCP Servers: .mcp.json present (MCP bridge not yet implemented)")
        }

        return .success(sections.joined(separator: "\n"))
    }

    // MARK: - Formatting

    private func formatPluginSummary(_ plugin: InstalledPlugin, action: String) -> String {
        let skillCount = plugin.skills.count
        let agentCount = plugin.agents.count
        var parts = ["\(action) plugin '\(plugin.manifest.name)'"]

        if let version = plugin.manifest.version {
            parts[0] += " v\(version)"
        }

        var details: [String] = []
        if skillCount > 0 { details.append("\(skillCount) skill\(skillCount == 1 ? "" : "s")") }
        if agentCount > 0 { details.append("\(agentCount) agent\(agentCount == 1 ? "" : "s")") }

        if !details.isEmpty {
            parts.append("Components: \(details.joined(separator: ", "))")
        }

        parts.append("Description: \(plugin.manifest.description)")

        if !plugin.skills.isEmpty {
            parts.append("Skills: \(plugin.skills.map(\.name).joined(separator: ", "))")
        }
        if !plugin.agents.isEmpty {
            parts.append("Agents: \(plugin.agents.map(\.name).joined(separator: ", "))")
        }

        return parts.joined(separator: "\n")
    }
}
