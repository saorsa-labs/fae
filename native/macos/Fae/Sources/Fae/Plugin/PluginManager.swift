import Foundation

/// Manages the lifecycle of installed plugins.
///
/// Plugins are stored at `~/.fae-plugins/` and follow the Claude Code plugin format
/// (`.claude-plugin/plugin.json` manifest with optional `skills/`, `agents/`, `.mcp.json`).
///
/// Plugin skills are exposed to `SkillManager` via the `pluginsDirectory` discovery root.
/// Plugin agents are converted to instruction skills.
actor PluginManager {

    /// Root directory for installed plugins.
    static var pluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-plugins", isDirectory: true)
    }

    /// State file tracking enabled/disabled plugins.
    private static var stateFileURL: URL {
        pluginsDirectory.appendingPathComponent(".plugin-state.json")
    }

    private var installedPlugins: [String: InstalledPlugin] = [:]
    private var disabledPlugins: Set<String> = []

    /// MCP bridge for connecting to plugin MCP servers.
    let mcpBridge = MCPBridge()

    /// Hook runner for executing plugin hooks at lifecycle points.
    let hookRunner = PluginHookRunner()

    // MARK: - Initialization

    /// Ensure the plugins directory exists, load state, discover plugins, start MCP servers, and load hooks.
    func initialize() async {
        let fm = FileManager.default
        let dir = Self.pluginsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        loadState()
        let plugins = discoverPlugins()

        // Start MCP servers for plugins that have .mcp.json.
        await mcpBridge.startServers(for: plugins)

        // Load hooks from all plugins.
        await hookRunner.loadHooks(from: plugins)
    }

    /// Shut down all MCP connections and clean up.
    func shutdown() async {
        await mcpBridge.stopAll()
    }

    // MARK: - Discovery

    /// Scan `~/.fae-plugins/` for installed plugins.
    func discoverPlugins() -> [InstalledPlugin] {
        let fm = FileManager.default
        let dir = Self.pluginsDirectory
        installedPlugins.removeAll()

        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }

            // Skip hidden files.
            guard !url.lastPathComponent.hasPrefix(".") else { continue }

            guard var plugin = PluginLoader.load(from: url) else { continue }

            if disabledPlugins.contains(plugin.id) {
                plugin.isEnabled = false
            }

            installedPlugins[plugin.id] = plugin
        }

        return Array(installedPlugins.values).sorted { $0.id < $1.id }
    }

    /// Return all skill metadata from all enabled plugins.
    ///
    /// This is the bridge between the plugin system and SkillManager —
    /// plugin skills appear in the skill discovery results.
    func allPluginSkillMetadata() -> [SkillMetadata] {
        var results: [SkillMetadata] = []

        for plugin in installedPlugins.values where plugin.isEnabled {
            for skill in plugin.skills {
                results.append(skill.metadata)
            }
            for agent in plugin.agents {
                results.append(agent.metadata)
            }
        }

        return results
    }

    /// Get a specific plugin by ID.
    func plugin(named id: String) -> InstalledPlugin? {
        installedPlugins[id]
    }

    /// List all installed plugins.
    func listPlugins() -> [InstalledPlugin] {
        Array(installedPlugins.values).sorted { $0.id < $1.id }
    }

    /// Count of MCP tools connected for a specific plugin.
    func mcpToolCount(for pluginId: String) async -> Int {
        await mcpBridge.toolCount(for: pluginId)
    }

    // MARK: - Install

    /// Install a plugin from a git URL.
    ///
    /// Clones the repository into `~/.fae-plugins/<name>/` and validates the manifest.
    func install(from source: PluginSource, name: String? = nil) async throws -> InstalledPlugin {
        let fm = FileManager.default
        let pluginsDir = Self.pluginsDirectory

        switch source {
        case .git(let url, let ref):
            // Derive name from URL if not provided.
            let pluginName = try name ?? derivePluginName(from: url)

            let targetDir = pluginsDir.appendingPathComponent(pluginName)
            if fm.fileExists(atPath: targetDir.path) {
                throw PluginError.alreadyInstalled(pluginName)
            }

            // Clone the repository.
            try await gitClone(url: url, ref: ref, destination: targetDir)

            // Validate the plugin.
            guard let plugin = PluginLoader.load(from: targetDir) else {
                // Clean up invalid clone.
                try? fm.removeItem(at: targetDir)
                throw PluginError.invalidManifest(
                    "Cloned repository does not contain a valid .claude-plugin/plugin.json"
                )
            }

            installedPlugins[plugin.id] = plugin
            await refreshMCPAndHooks(for: plugin)
            NSLog("PluginManager: installed plugin '%@' from %@", plugin.id, url)
            return plugin

        case .local(let path):
            let sourceURL = URL(fileURLWithPath: path).standardized
            guard fm.fileExists(atPath: sourceURL.path) else {
                throw PluginError.installFailed("Source path does not exist: \(path)")
            }

            // Validate before copying.
            guard let sourcePlugin = PluginLoader.load(from: sourceURL) else {
                throw PluginError.invalidManifest(
                    "Source directory does not contain a valid .claude-plugin/plugin.json"
                )
            }

            let pluginName = name ?? sourcePlugin.manifest.name
            let targetDir = pluginsDir.appendingPathComponent(pluginName)
            if fm.fileExists(atPath: targetDir.path) {
                throw PluginError.alreadyInstalled(pluginName)
            }

            try fm.copyItem(at: sourceURL, to: targetDir)

            guard let plugin = PluginLoader.load(from: targetDir) else {
                try? fm.removeItem(at: targetDir)
                throw PluginError.invalidManifest("Copy produced invalid plugin")
            }

            installedPlugins[plugin.id] = plugin
            await refreshMCPAndHooks(for: plugin)
            NSLog("PluginManager: installed plugin '%@' from local path", plugin.id)
            return plugin
        }
    }

    /// Install a plugin from a git URL that contains multiple plugins in subdirectories.
    ///
    /// Used for repos like `claude-plugins-official` where plugins live under `plugins/` or `external_plugins/`.
    func installFromMonorepo(
        repoURL: String,
        pluginPath: String,
        name: String? = nil,
        ref: String? = nil
    ) async throws -> InstalledPlugin {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        defer { try? fm.removeItem(at: tempDir) }

        guard !pluginPath.contains(".."), !pluginPath.hasPrefix("/"), !pluginPath.contains("~") else {
            throw PluginError.installFailed("Invalid plugin path: '\(pluginPath)'")
        }

        // Sparse clone or full clone + extract.
        try await gitClone(url: repoURL, ref: ref, destination: tempDir)

        let pluginSourceDir = tempDir.appendingPathComponent(pluginPath)
        guard fm.fileExists(atPath: pluginSourceDir.path) else {
            throw PluginError.installFailed(
                "Plugin path '\(pluginPath)' not found in repository"
            )
        }

        return try await install(from: .local(path: pluginSourceDir.path), name: name)
    }

    // MARK: - Remove

    /// Remove an installed plugin.
    func remove(pluginId: String) async throws {
        guard let plugin = installedPlugins[pluginId] else {
            throw PluginError.notFound(pluginId)
        }

        // Stop MCP servers for this plugin.
        await mcpBridge.stopServers(for: pluginId)

        do {
            try FileManager.default.removeItem(at: plugin.directoryURL)
            installedPlugins.removeValue(forKey: pluginId)
            disabledPlugins.remove(pluginId)
            saveState()
            // Reload hooks (removed plugin's hooks are gone).
            await hookRunner.loadHooks(from: Array(installedPlugins.values))
            NSLog("PluginManager: removed plugin '%@'", pluginId)
        } catch {
            throw PluginError.removeFailed(error.localizedDescription)
        }
    }

    // MARK: - Enable / Disable

    /// Enable a disabled plugin.
    func enable(pluginId: String) throws {
        guard var plugin = installedPlugins[pluginId] else {
            throw PluginError.notFound(pluginId)
        }
        plugin.isEnabled = true
        installedPlugins[pluginId] = plugin
        disabledPlugins.remove(pluginId)
        saveState()
    }

    /// Disable a plugin without removing it.
    func disable(pluginId: String) throws {
        guard var plugin = installedPlugins[pluginId] else {
            throw PluginError.notFound(pluginId)
        }
        plugin.isEnabled = false
        installedPlugins[pluginId] = plugin
        disabledPlugins.insert(pluginId)
        saveState()
    }

    // MARK: - Update

    /// Update a plugin by re-pulling from its git origin.
    func update(pluginId: String) async throws -> InstalledPlugin {
        guard let plugin = installedPlugins[pluginId] else {
            throw PluginError.notFound(pluginId)
        }

        let gitDir = plugin.directoryURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else {
            throw PluginError.installFailed("Plugin '\(pluginId)' was not installed from git")
        }

        // Pull latest.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", plugin.directoryURL.path, "pull", "--ff-only"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PluginError.installFailed("git pull failed for '\(pluginId)'")
        }

        // Reload.
        guard var updated = PluginLoader.load(from: plugin.directoryURL) else {
            throw PluginError.invalidManifest("Plugin invalid after update")
        }

        if disabledPlugins.contains(pluginId) {
            updated.isEnabled = false
        }

        installedPlugins[pluginId] = updated

        // Restart MCP servers and reload hooks for the updated plugin.
        await mcpBridge.stopServers(for: pluginId)
        await refreshMCPAndHooks(for: updated)

        NSLog("PluginManager: updated plugin '%@'", pluginId)
        return updated
    }

    // MARK: - Private

    /// Clone a git repository.
    private func gitClone(url: String, ref: String?, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")

        var args = ["clone", "--depth", "1"]
        if let ref {
            args += ["--branch", ref]
        }
        args += [url, destination.path]

        process.arguments = args
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw PluginError.gitCloneFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Derive a plugin name from a git URL and validate it is safe for use as a directory name.
    private func derivePluginName(from url: String) throws -> String {
        let components = url.components(separatedBy: "/")
        let lastComponent = components.last ?? url
        let name = lastComponent
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              !name.contains(".."),
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("~"),
              !name.hasPrefix(".")
        else {
            throw PluginError.installFailed("Invalid plugin name derived from URL: '\(name)'")
        }
        return name
    }

    /// Start MCP servers and reload hooks after a plugin is installed or updated.
    private func refreshMCPAndHooks(for plugin: InstalledPlugin) async {
        await mcpBridge.startServers(for: [plugin])
        await hookRunner.loadHooks(from: Array(installedPlugins.values))
    }

    // MARK: - State Persistence

    private struct PluginState: Codable {
        var disabled: [String]
    }

    private func loadState() {
        let url = Self.stateFileURL
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PluginState.self, from: data)
        else { return }
        disabledPlugins = Set(state.disabled)
    }

    private func saveState() {
        let state = PluginState(disabled: Array(disabledPlugins).sorted())
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateFileURL, options: .atomic)
    }
}
