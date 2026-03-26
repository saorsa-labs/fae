import Foundation
import Testing
@testable import Fae

@Suite("PluginLoader")
struct PluginLoaderTests {

    @Test("Load feature-dev plugin with agents")
    func loadFeatureDevPlugin() throws {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-plugins/feature-dev")

        // Skip if not installed.
        try #require(FileManager.default.fileExists(atPath: pluginDir.path))

        let plugin = PluginLoader.load(from: pluginDir)
        try #require(plugin != nil)

        let p = plugin!
        #expect(p.manifest.name == "feature-dev")
        #expect(p.manifest.description.contains("feature development"))
        #expect(p.manifest.author?.name == "Anthropic")

        // Should discover 3 agents.
        #expect(p.agents.count == 3)
        let agentNames = Set(p.agents.map(\.name))
        #expect(agentNames.contains("code-explorer"))
        #expect(agentNames.contains("code-architect"))
        #expect(agentNames.contains("code-reviewer"))

        // Agents should be instruction skills.
        for agent in p.agents {
            #expect(agent.metadata.type == .instruction)
            #expect(agent.metadata.tier == .community)
            #expect(agent.metadata.tags.contains("plugin"))
            #expect(agent.metadata.tags.contains("agent"))
        }
    }

    @Test("Load frontend-design plugin with skills")
    func loadFrontendDesignPlugin() throws {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-plugins/frontend-design")

        try #require(FileManager.default.fileExists(atPath: pluginDir.path))

        let plugin = PluginLoader.load(from: pluginDir)
        try #require(plugin != nil)

        let p = plugin!
        #expect(p.manifest.name == "frontend-design")
        #expect(p.skills.count == 1)
        #expect(p.skills[0].name == "frontend-design")
        #expect(p.skills[0].metadata.type == .instruction)
        #expect(p.skills[0].metadata.tags.contains("plugin"))
    }

    @Test("Load hookify plugin with hooks and agents")
    func loadHookifyPlugin() throws {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-plugins/hookify")

        try #require(FileManager.default.fileExists(atPath: pluginDir.path))

        let plugin = PluginLoader.load(from: pluginDir)
        try #require(plugin != nil)

        let p = plugin!
        #expect(p.manifest.name == "hookify")
        #expect(p.skills.count == 1) // writing-rules skill
        #expect(p.agents.count == 1) // conversation-analyzer agent

        // Verify hooks can be parsed.
        let hookConfig = PluginHookConfig.load(from: pluginDir)
        try #require(hookConfig != nil)

        let hooks = hookConfig!.hooks
        #expect(hooks[.preToolUse] != nil)
        #expect(hooks[.postToolUse] != nil)
        #expect(hooks[.stop] != nil)
        #expect(hooks[.userPromptSubmit] != nil)

        // Verify command substitution.
        if let preToolHooks = hooks[.preToolUse] {
            #expect(preToolHooks.count == 1)
            #expect(preToolHooks[0].command.contains("pretooluse.py"))
            #expect(!preToolHooks[0].command.contains("${CLAUDE_PLUGIN_ROOT}"))
            #expect(preToolHooks[0].timeout == 10)
        }
    }

    @Test("Load slack plugin with MCP config")
    func loadSlackPlugin() throws {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-plugins/slack")

        try #require(FileManager.default.fileExists(atPath: pluginDir.path))

        let plugin = PluginLoader.load(from: pluginDir)
        try #require(plugin != nil)

        let p = plugin!
        #expect(p.manifest.name == "slack")

        // Verify MCP config can be parsed.
        let mcpConfig = MCPServerConfig.load(from: pluginDir)
        try #require(mcpConfig != nil)

        let servers = mcpConfig!.servers
        #expect(servers.count == 1)
        #expect(servers["slack"] != nil)

        if case .http(let url, let oauth) = servers["slack"] {
            #expect(url.absoluteString == "https://mcp.slack.com/mcp")
            #expect(oauth?.clientId == "1601185624273.8899143856786")
            #expect(oauth?.callbackPort == 3118)
        } else {
            Issue.record("Expected HTTP server for slack")
        }
    }

    @Test("Load code-review plugin (commands only, no skills/agents)")
    func loadCodeReviewPlugin() throws {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-plugins/code-review")

        try #require(FileManager.default.fileExists(atPath: pluginDir.path))

        let plugin = PluginLoader.load(from: pluginDir)
        try #require(plugin != nil)

        let p = plugin!
        #expect(p.manifest.name == "code-review")
        // code-review uses commands/ not skills/ — so no skills/agents discovered.
        // This is expected — commands/ support is for future work.
        #expect(p.skills.count == 0)
        #expect(p.agents.count == 0)
    }

    @Test("PluginManager discovers all installed plugins")
    func pluginManagerDiscovery() async throws {
        let manager = PluginManager()

        // Don't call full initialize() (which starts MCP servers).
        // Just test discovery.
        let plugins = await manager.discoverPlugins()

        // Should find all 5 installed plugins.
        #expect(plugins.count >= 5)

        let names = Set(plugins.map(\.id))
        #expect(names.contains("feature-dev"))
        #expect(names.contains("frontend-design"))
        #expect(names.contains("hookify"))
        #expect(names.contains("slack"))
        #expect(names.contains("code-review"))

        // All should be enabled by default.
        for plugin in plugins {
            #expect(plugin.isEnabled)
        }
    }

    @Test("Plugin skills appear in allPluginSkillMetadata")
    func pluginSkillMetadata() async throws {
        let manager = PluginManager()
        _ = await manager.discoverPlugins()

        let skills = await manager.allPluginSkillMetadata()

        // Should include feature-dev agents + frontend-design skill + hookify skill + hookify agent.
        let skillNames = Set(skills.map(\.name))
        #expect(skillNames.contains("code-explorer"))
        #expect(skillNames.contains("code-architect"))
        #expect(skillNames.contains("code-reviewer"))
        #expect(skillNames.contains("frontend-design"))
    }
}
