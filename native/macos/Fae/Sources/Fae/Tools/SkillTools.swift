import Foundation

/// Tool to load full SKILL.md body into LLM context.
///
/// Low-risk: only reads skill files and injects instructions.
struct ActivateSkillTool: Tool {
    let name = "activate_skill"
    let description = "Load a skill's full instructions into context. Use when a task matches a skill description."
    let parametersSchema = #"{"name": "string (required — skill name to activate)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"activate_skill","arguments":{"name":"weather-check"}}</tool_call>"#

    private let skillManager: SkillManager

    init(skillManager: SkillManager) {
        self.skillManager = skillManager
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let skillName = input["name"] as? String,
              !skillName.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .error("Missing required parameter: name")
        }

        if let body = await skillManager.activate(skillName: skillName) {
            return .success("Skill '\(skillName)' activated. Instructions:\n\n\(body)")
        } else {
            return .error("Skill '\(skillName)' not found or has no instructions.")
        }
    }
}

/// Tool to run an installed Python skill by name.
///
/// Medium-risk: executes Python scripts via `uv run`.
struct RunSkillTool: Tool {
    let name = "run_skill"
    let description = "Run an installed Python skill by name. Use this instead of composing bash commands with skill paths."
    let parametersSchema = #"{"name":"string (required — skill name)","script":"string (optional — specific script name for multi-script skills)","params":{"type":"object","description":"optional structured parameters forwarded to the skill as request.params"},"input":"string (optional — compatibility shortcut forwarded as params.input when params.input is absent)","secret_bindings":{"type":"object","description":"optional map of ENV_VAR -> keychain key. Secret values are injected into the skill process environment and are never written into the prompt or request JSON"}}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .medium
    let example = #"<tool_call>{"name":"run_skill","arguments":{"name":"mesh","script":"discover","params":{"method":"bonjour","timeout":5}}}</tool_call>"#

    private let skillManager: SkillManager

    init(skillManager: SkillManager) {
        self.skillManager = skillManager
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let skillName = input["name"] as? String,
              !skillName.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .error("Missing required parameter: name")
        }

        guard let capabilityTicket = input["capability_ticket"] as? String,
              !capabilityTicket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .error("Missing required parameter: capability_ticket")
        }

        let scriptName = input["script"] as? String
        var skillInput: [String: Any] = SkillManager.audioContextForSkill()
        if let params = input["params"] as? [String: Any] {
            for (key, value) in params {
                skillInput[key] = value
            }
        }
        if let text = input["input"] as? String {
            if skillInput["input"] == nil {
                skillInput["input"] = text
            }
        }
        let secretBindings = parseStringMap(input["secret_bindings"]) ?? [:]

        do {
            let output = try await skillManager.execute(
                skillName: skillName,
                scriptName: scriptName,
                input: skillInput,
                capabilityTicketId: capabilityTicket,
                secretBindings: secretBindings
            )
            let truncated = output.count > 20_000
                ? String(output.prefix(20_000)) + "\n[truncated]"
                : output
            return .success(truncated)
        } catch {
            return .error("Skill execution failed: \(error.localizedDescription)")
        }
    }

    private func parseStringMap(_ raw: Any?) -> [String: String]? {
        guard let rawDict = raw as? [String: Any] else { return nil }
        var parsed: [String: String] = [:]
        for (key, value) in rawDict {
            guard let stringValue = value as? String else { return nil }
            parsed[key] = stringValue
        }
        return parsed
    }
}

/// Tool to create, update, or delete personal skills.
///
/// High-risk: modifies the skills directory.
struct ManageSkillTool: Tool {
    let name = "manage_skill"
    let description = "Create, update, or delete personal skills. Actions: create, update, delete, list."
    let parametersSchema = #"{"action": "string (required: create|update|delete|list)", "name": "string (required for create/update/delete)", "description": "string (required for create, optional for update — what the skill does)", "body": "string (required for create, optional for update — SKILL.md instructions)", "script": "string (optional for create — Python script content)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"manage_skill","arguments":{"action":"create","name":"weather-check","description":"Check weather for a city","body":"Search for weather using web_search tool."}}</tool_call>"#

    private let skillManager: SkillManager

    init(skillManager: SkillManager) {
        self.skillManager = skillManager
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action (create|delete|list)")
        }

        switch action {
        case "create":
            return await handleCreate(input: input)
        case "update":
            return await handleUpdate(input: input)
        case "delete":
            return await handleDelete(input: input)
        case "list":
            return await handleList()
        default:
            return .error("Unknown action '\(action)'. Use: create, update, delete, list")
        }
    }

    private func handleCreate(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }
        guard let description = input["description"] as? String, !description.isEmpty else {
            return .error("Missing required parameter: description")
        }
        guard let body = input["body"] as? String else {
            return .error("Missing required parameter: body")
        }

        let script = input["script"] as? String

        do {
            let metadata = try await skillManager.createSkill(
                name: name,
                description: description,
                body: body,
                scriptContent: script
            )
            let typeLabel = metadata.type == .executable ? "executable" : "instruction"
            return .success("Created \(typeLabel) skill '\(name)': \(description)")
        } catch {
            return .error("Failed to create skill: \(error.localizedDescription)")
        }
    }

    private func handleUpdate(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }

        let description = input["description"] as? String
        let body = input["body"] as? String

        guard description != nil || body != nil else {
            return .error("At least one of 'description' or 'body' must be provided for update.")
        }

        do {
            let metadata = try await skillManager.updateSkill(
                name: name,
                description: description,
                body: body
            )
            return .success("Updated skill '\(metadata.name)' successfully.")
        } catch {
            return .error("Failed to update skill: \(error.localizedDescription)")
        }
    }

    private func handleDelete(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }

        do {
            try await skillManager.deleteSkill(name: name)
            return .success("Deleted skill '\(name)'.")
        } catch {
            return .error("Failed to delete skill: \(error.localizedDescription)")
        }
    }

    private func handleList() async -> ToolResult {
        let skills = await skillManager.discoverSkills()
        if skills.isEmpty {
            return .success("No skills installed.")
        }

        let lines = skills.map { skill in
            let typeTag = skill.type == .executable ? " [executable]" : ""
            let tierTag = skill.tier == .builtin ? " [built-in]" : ""
            return "- \(skill.name): \(skill.description)\(typeTag)\(tierTag)"
        }
        return .success("Installed skills:\n" + lines.joined(separator: "\n"))
    }
}
