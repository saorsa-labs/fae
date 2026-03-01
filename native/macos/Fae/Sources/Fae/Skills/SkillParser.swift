import Foundation

/// Parses SKILL.md files following the Agent Skills specification.
///
/// Expects YAML frontmatter delimited by `---` at the top of the file,
/// with at minimum `name` and `description` fields.
enum SkillParser {

    /// Parse a SKILL.md file and return metadata only (no body).
    static func parse(
        skillURL: URL,
        tier: SkillTier,
        isEnabled: Bool = true
    ) -> SkillMetadata? {
        guard let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return nil
        }
        let (frontmatter, _) = splitFrontmatter(content)
        guard let fm = frontmatter else { return nil }
        return buildMetadata(from: fm, skillURL: skillURL, tier: tier, isEnabled: isEnabled)
    }

    /// Parse SKILL.md and return full record including body.
    static func parseRecord(
        skillURL: URL,
        tier: SkillTier,
        isEnabled: Bool = true
    ) -> SkillRecord? {
        guard let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return nil
        }
        let (frontmatter, body) = splitFrontmatter(content)
        guard let fm = frontmatter,
              let metadata = buildMetadata(
                  from: fm, skillURL: skillURL, tier: tier, isEnabled: isEnabled
              )
        else {
            return nil
        }
        return SkillRecord(metadata: metadata, fullBody: body)
    }

    // MARK: - Private

    /// Split SKILL.md content into frontmatter dict and body string.
    private static func splitFrontmatter(_ content: String) -> ([String: String]?, String?) {
        let lines = content.components(separatedBy: .newlines)
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, content)
        }

        // Find closing ---
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
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let dict = parseSimpleYAML(yamlLines)
        return (dict, body.isEmpty ? nil : body)
    }

    /// Minimal YAML key:value parser — handles flat keys and one level of nesting.
    ///
    /// Supports:
    /// ```yaml
    /// name: weather-check
    /// description: Check weather for a city.
    /// metadata:
    ///   author: fae
    ///   version: "1.0"
    /// ```
    private static func parseSimpleYAML(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var currentParent: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if indent >= 2, let parent = currentParent {
                // Nested key
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[trimmed.startIndex ..< colonIdx])
                        .trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: colonIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !key.isEmpty, !value.isEmpty {
                        result["\(parent).\(key)"] = value
                    }
                }
            } else if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex ..< colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if value.isEmpty {
                    // This is a parent key (e.g. "metadata:")
                    currentParent = key
                } else {
                    result[key] = value
                    currentParent = nil
                }
            }
        }

        return result
    }

    /// Build SkillMetadata from parsed YAML frontmatter.
    private static func buildMetadata(
        from yaml: [String: String],
        skillURL: URL,
        tier: SkillTier,
        isEnabled: Bool
    ) -> SkillMetadata? {
        guard let name = yaml["name"], !name.isEmpty,
              let description = yaml["description"], !description.isEmpty
        else {
            return nil
        }

        let skillDir = skillURL.deletingLastPathComponent()
        let scriptsDir = skillDir.appendingPathComponent("scripts")
        let hasScripts = FileManager.default.fileExists(atPath: scriptsDir.path)
        let type: SkillType = hasScripts ? .executable : .instruction

        return SkillMetadata(
            name: name,
            description: description,
            author: yaml["metadata.author"],
            version: yaml["metadata.version"],
            type: type,
            tier: tier,
            isEnabled: isEnabled,
            directoryURL: skillDir
        )
    }
}
