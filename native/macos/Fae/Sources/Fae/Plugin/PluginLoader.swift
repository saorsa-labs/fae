import Foundation

/// Loads and parses Claude Code plugin directories into Fae-compatible structures.
///
/// Supports the `.claude-plugin/plugin.json` format with `skills/` and `agents/` subdirectories.
/// Plugin skills are translated into Fae `SkillMetadata` with tier `.community`.
enum PluginLoader {

    /// Load a plugin from its root directory.
    ///
    /// Expects `.claude-plugin/plugin.json` to exist. Scans for skills and agents.
    static func load(from directory: URL) -> InstalledPlugin? {
        let manifestURL = directory
            .appendingPathComponent(".claude-plugin")
            .appendingPathComponent("plugin.json")

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            return nil
        }

        let skills = discoverSkills(in: directory, pluginName: manifest.name)
        let agents = discoverAgents(in: directory, pluginName: manifest.name)

        return InstalledPlugin(
            manifest: manifest,
            directoryURL: directory,
            skills: skills,
            agents: agents,
            isEnabled: true
        )
    }

    // MARK: - Skill Discovery

    /// Scan `skills/` directory for SKILL.md files.
    ///
    /// Claude plugins use `skills/<name>/SKILL.md` — same layout as Fae.
    /// Frontmatter differences are translated:
    /// - `user-invocable` → ignored (Fae uses activation model)
    /// - `allowed-tools` → stored in tags for reference
    /// - `argument-hint` → appended to description
    private static func discoverSkills(in pluginDir: URL, pluginName: String) -> [PluginSkillEntry] {
        let skillsDir = pluginDir.appendingPathComponent("skills")
        let fm = FileManager.default

        guard fm.fileExists(atPath: skillsDir.path) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var entries: [PluginSkillEntry] = []

        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let skillMd = url.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillMd.path) else { continue }

            // Try Fae's native parser first — works if frontmatter has name + description.
            if let metadata = SkillParser.parse(
                skillURL: skillMd,
                tier: .community,
                isEnabled: true
            ) {
                // Add plugin tag for identification.
                let taggedMetadata = SkillMetadata(
                    name: metadata.name,
                    description: metadata.description,
                    author: metadata.author ?? pluginName,
                    version: metadata.version,
                    tags: metadata.tags + ["plugin", "plugin:\(pluginName)"],
                    type: metadata.type,
                    tier: .community,
                    isEnabled: true,
                    directoryURL: metadata.directoryURL
                )
                entries.append(PluginSkillEntry(
                    name: metadata.name,
                    skillURL: skillMd,
                    metadata: taggedMetadata
                ))
                continue
            }

            // Fallback: parse Claude-format frontmatter manually.
            if let metadata = parseClaudeSkill(skillMd: skillMd, pluginName: pluginName) {
                entries.append(PluginSkillEntry(
                    name: metadata.name,
                    skillURL: skillMd,
                    metadata: metadata
                ))
            }
        }

        return entries
    }

    /// Parse a Claude Code SKILL.md that uses Claude-specific frontmatter keys.
    ///
    /// Claude format:
    /// ```yaml
    /// ---
    /// name: skill-name
    /// description: When to use...
    /// user-invocable: true
    /// allowed-tools: [Read, Glob, Bash]
    /// argument-hint: <arg>
    /// ---
    /// ```
    private static func parseClaudeSkill(skillMd: URL, pluginName: String) -> SkillMetadata? {
        guard let content = try? String(contentsOf: skillMd, encoding: .utf8) else {
            return nil
        }

        let (frontmatter, _) = splitFrontmatter(content)
        guard let fm = frontmatter else { return nil }

        let name = fm["name"]
        let description = fm["description"]

        guard let skillName = name, !skillName.isEmpty,
              let skillDesc = description, !skillDesc.isEmpty
        else {
            return nil
        }

        // Build enriched description with argument hint if present.
        var fullDescription = skillDesc
        if let argHint = fm["argument-hint"], !argHint.isEmpty {
            fullDescription += " Usage: \(argHint)"
        }

        let skillDir = skillMd.deletingLastPathComponent()
        let scriptsDir = skillDir.appendingPathComponent("scripts")
        let hasScripts = FileManager.default.fileExists(atPath: scriptsDir.path)

        var tags = ["plugin", "plugin:\(pluginName)"]

        // Capture allowed-tools as tags for reference.
        if let allowedTools = fm["allowed-tools"] {
            let cleaned = allowedTools
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for tool in cleaned {
                tags.append("tool:\(tool.lowercased())")
            }
        }

        return SkillMetadata(
            name: skillName,
            description: fullDescription,
            author: pluginName,
            version: fm["version"],
            tags: tags,
            type: hasScripts ? .executable : .instruction,
            tier: .community,
            isEnabled: true,
            directoryURL: skillDir
        )
    }

    // MARK: - Agent Discovery

    /// Scan `agents/` directory for markdown agent definitions.
    ///
    /// Claude agents are `.md` files with YAML frontmatter defining name, description,
    /// model, tools, color. Converted to Fae instruction skills.
    private static func discoverAgents(in pluginDir: URL, pluginName: String) -> [PluginAgentEntry] {
        let agentsDir = pluginDir.appendingPathComponent("agents")
        let fm = FileManager.default

        guard fm.fileExists(atPath: agentsDir.path) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var entries: [PluginAgentEntry] = []

        for url in contents {
            guard url.pathExtension == "md" else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let (frontmatter, _) = splitFrontmatter(content)
            guard let fm = frontmatter,
                  let agentName = fm["name"], !agentName.isEmpty
            else { continue }

            let description = fm["description"] ?? "Agent from \(pluginName) plugin"

            // Create a synthetic skill directory for the agent.
            // Agents are instruction-only — their body becomes the skill body.
            let agentDir = url.deletingLastPathComponent()

            let metadata = SkillMetadata(
                name: agentName,
                description: description,
                author: pluginName,
                version: nil,
                tags: ["plugin", "plugin:\(pluginName)", "agent"],
                type: .instruction,
                tier: .community,
                isEnabled: true,
                directoryURL: agentDir
            )

            entries.append(PluginAgentEntry(
                name: agentName,
                fileURL: url,
                metadata: metadata
            ))
        }

        return entries
    }

    // MARK: - Frontmatter Parsing

    /// Split markdown content into YAML frontmatter dict and body.
    /// Reuses the same logic as SkillParser but accessible here.
    private static func splitFrontmatter(_ content: String) -> ([String: String]?, String?) {
        let lines = content.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces) == "---"
        else {
            return (nil, content)
        }

        var closingIndex: Int?
        for i in 1 ..< lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }
        guard let endIdx = closingIndex else {
            return (nil, content)
        }

        let yamlLines = Array(lines[1 ..< endIdx])
        let bodyLines = Array(lines[(endIdx + 1)...])
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var dict: [String: String] = [:]
        // Support multi-line description values (pipes).
        var currentKey: String?
        var multilineValue: [String] = []

        func flushMultiline() {
            if let key = currentKey, !multilineValue.isEmpty {
                dict[key] = multilineValue.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            currentKey = nil
            multilineValue = []
        }

        for line in yamlLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            // Continuation of multiline value.
            if indent >= 2, currentKey != nil {
                multilineValue.append(trimmed)
                continue
            }

            flushMultiline()

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex ..< colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

                if value.isEmpty || value == "|" || value == ">" {
                    currentKey = key
                } else if value.hasPrefix("[") && value.hasSuffix("]") {
                    // Inline list.
                    let inner = value.dropFirst().dropLast()
                    let items = inner.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                        .filter { !$0.isEmpty }
                    dict[key] = items.joined(separator: ",")
                } else {
                    dict[key] = value
                }
            }
        }

        flushMultiline()
        return (dict.isEmpty ? nil : dict, body.isEmpty ? nil : body)
    }
}
