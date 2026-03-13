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
    let description = "Create, update, patch, script, review, apply, or delete personal skills and staged skill drafts."
    let parametersSchema = #"{"action": "string (required: create|update|patch|update_script|write_reference_file|replace_manifest|delete|list|list_drafts|show_draft|apply_draft|dismiss_draft)", "name": "string (required for create/update/patch/update_script/write_reference_file/replace_manifest/delete)", "description": "string (required for create, optional for update — what the skill does)", "body": "string (required for create, optional for update — SKILL.md instructions)", "script": "string (optional for create/update_script/apply_draft — Python script content)", "script_name": "string (optional for create/update_script — custom filename under scripts/)", "manifest_json": "string (optional for create/update_script/replace_manifest/apply_draft — full MANIFEST.json content)", "find_text": "string (required for patch — exact body text to replace)", "replace_with": "string (required for patch — replacement body text)", "replace_all": "boolean (optional for patch — replace every matching body span)", "relative_path": "string (required for write_reference_file — path under references/ or assets/)", "content": "string (required for write_reference_file — file content)", "draft_id": "string (required for show_draft/apply_draft/dismiss_draft)", "status": "string (optional for list_drafts — pending|dismissed|applied)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"manage_skill","arguments":{"action":"create","name":"weather-check","description":"Check weather for a city","body":"Search for weather using web_search tool."}}</tool_call>"#

    private let skillManager: SkillManager
    private let workflowTraceStore: WorkflowTraceStore?

    init(skillManager: SkillManager, workflowTraceStore: WorkflowTraceStore? = nil) {
        self.skillManager = skillManager
        self.workflowTraceStore = workflowTraceStore
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "create":
            return await handleCreate(input: input)
        case "update":
            return await handleUpdate(input: input)
        case "patch":
            return await handlePatch(input: input)
        case "update_script":
            return await handleUpdateScript(input: input)
        case "write_reference_file":
            return await handleWriteReferenceFile(input: input)
        case "replace_manifest":
            return await handleReplaceManifest(input: input)
        case "delete":
            return await handleDelete(input: input)
        case "list":
            return await handleList()
        case "list_drafts":
            return await handleListDrafts(input: input)
        case "show_draft":
            return await handleShowDraft(input: input)
        case "apply_draft":
            return await handleApplyDraft(input: input)
        case "dismiss_draft":
            return await handleDismissDraft(input: input)
        default:
            return .error("Unknown action '\(action)'. Use: create, update, patch, update_script, write_reference_file, replace_manifest, delete, list, list_drafts, show_draft, apply_draft, dismiss_draft")
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
        let scriptName = input["script_name"] as? String
        let manifestJSON = input["manifest_json"] as? String

        do {
            let metadata = try await skillManager.createSkill(
                name: name,
                description: description,
                body: body,
                scriptContent: script,
                scriptName: scriptName,
                manifestJSON: manifestJSON
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

    private func handlePatch(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }
        guard let findText = input["find_text"] as? String else {
            return .error("Missing required parameter: find_text")
        }
        guard let replaceWith = input["replace_with"] as? String else {
            return .error("Missing required parameter: replace_with")
        }

        do {
            let metadata = try await skillManager.patchSkill(
                name: name,
                findText: findText,
                replaceWith: replaceWith,
                replaceAll: input["replace_all"] as? Bool ?? false
            )
            return .success("Patched skill '\(metadata.name)' successfully.")
        } catch {
            return .error("Failed to patch skill: \(error.localizedDescription)")
        }
    }

    private func handleUpdateScript(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }
        guard let script = input["script"] as? String else {
            return .error("Missing required parameter: script")
        }
        guard let scriptName = input["script_name"] as? String, !scriptName.isEmpty else {
            return .error("Missing required parameter: script_name")
        }

        do {
            let metadata = try await skillManager.writeSkillScript(
                name: name,
                scriptName: scriptName,
                scriptContent: script,
                manifestJSON: input["manifest_json"] as? String
            )
            return .success("Updated script '\(scriptName)' for skill '\(metadata.name)'.")
        } catch {
            return .error("Failed to update skill script: \(error.localizedDescription)")
        }
    }

    private func handleWriteReferenceFile(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }
        guard let relativePath = input["relative_path"] as? String, !relativePath.isEmpty else {
            return .error("Missing required parameter: relative_path")
        }
        guard let content = input["content"] as? String else {
            return .error("Missing required parameter: content")
        }

        do {
            try await skillManager.writeSkillReferenceFile(
                name: name,
                relativePath: relativePath,
                content: content
            )
            return .success("Wrote '\(relativePath)' for skill '\(name)'.")
        } catch {
            return .error("Failed to write skill reference file: \(error.localizedDescription)")
        }
    }

    private func handleReplaceManifest(input: [String: Any]) async -> ToolResult {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .error("Missing required parameter: name")
        }
        guard let manifestJSON = input["manifest_json"] as? String else {
            return .error("Missing required parameter: manifest_json")
        }

        do {
            let metadata = try await skillManager.replaceSkillManifest(
                name: name,
                manifestJSON: manifestJSON
            )
            return .success("Replaced MANIFEST.json for skill '\(metadata.name)'.")
        } catch {
            return .error("Failed to replace skill manifest: \(error.localizedDescription)")
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

    private func handleListDrafts(input: [String: Any]) async -> ToolResult {
        guard let workflowTraceStore else {
            return .error("Skill drafts are not available in this runtime.")
        }

        let statuses: [SkillDraftCandidateStatus]?
        if let status = input["status"] as? String, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = SkillDraftCandidateStatus(rawValue: status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                return .error("Unknown draft status '\(status)'. Use pending, dismissed, or applied.")
            }
            statuses = [parsed]
        } else {
            statuses = nil
        }

        do {
            let drafts = try await workflowTraceStore.listDraftCandidates(statuses: statuses)
            if drafts.isEmpty {
                return .success("No skill drafts available.")
            }

            let lines = drafts.map { draft in
                let confidence = Int((draft.confidence * 100).rounded())
                return "- \(draft.id): [\(draft.status.rawValue)] \(draft.title) → \(draft.action.rawValue) \(draft.targetSkillName) (\(confidence)% confidence)"
            }
            return .success("Skill drafts:\n" + lines.joined(separator: "\n"))
        } catch {
            return .error("Failed to list skill drafts: \(error.localizedDescription)")
        }
    }

    private func handleShowDraft(input: [String: Any]) async -> ToolResult {
        guard let workflowTraceStore else {
            return .error("Skill drafts are not available in this runtime.")
        }
        guard let draftID = input["draft_id"] as? String, !draftID.isEmpty else {
            return .error("Missing required parameter: draft_id")
        }

        do {
            guard let draft = try await workflowTraceStore.fetchDraftCandidate(id: draftID) else {
                return .error("Skill draft '\(draftID)' not found.")
            }

            var sections: [String] = [
                "Draft ID: \(draft.id)",
                "Status: \(draft.status.rawValue)",
                "Action: \(draft.action.rawValue)",
                "Target skill: \(draft.targetSkillName)",
                String(format: "Confidence: %.0f%%", draft.confidence * 100),
                "",
                "Rationale:",
                draft.rationale,
            ]
            if let evidence = draft.evidenceJSON, !evidence.isEmpty {
                sections.append("")
                sections.append("Evidence JSON:")
                sections.append(evidence)
            }
            sections.append("")
            sections.append("Draft SKILL.md:")
            sections.append(draft.draftSkillMD)
            if let manifest = draft.draftManifestJSON, !manifest.isEmpty {
                sections.append("")
                sections.append("Draft MANIFEST.json:")
                sections.append(manifest)
            }
            if let script = draft.draftScript, !script.isEmpty {
                sections.append("")
                sections.append("Draft script:")
                sections.append(script)
            }
            return .success(sections.joined(separator: "\n"))
        } catch {
            return .error("Failed to load skill draft: \(error.localizedDescription)")
        }
    }

    private func handleApplyDraft(input: [String: Any]) async -> ToolResult {
        guard let workflowTraceStore else {
            return .error("Skill drafts are not available in this runtime.")
        }
        guard let draftID = input["draft_id"] as? String, !draftID.isEmpty else {
            return .error("Missing required parameter: draft_id")
        }

        do {
            guard let draft = try await workflowTraceStore.fetchDraftCandidate(id: draftID) else {
                return .error("Skill draft '\(draftID)' not found.")
            }

            let parsed = try SkillManager.parseSkillMarkdown(
                draft.draftSkillMD,
                fallbackName: draft.targetSkillName
            )

            let targetName = draft.targetSkillName
            let metadata: SkillMetadata
            switch draft.action {
            case .create:
                metadata = try await skillManager.createSkill(
                    name: targetName,
                    description: parsed.description,
                    body: parsed.body,
                    scriptContent: draft.draftScript,
                    scriptName: targetName,
                    manifestJSON: draft.draftManifestJSON
                )
            case .update:
                metadata = try await skillManager.updateSkill(
                    name: targetName,
                    description: parsed.description,
                    body: parsed.body
                )
                if let script = draft.draftScript, !script.isEmpty {
                    _ = try await skillManager.writeSkillScript(
                        name: targetName,
                        scriptName: targetName,
                        scriptContent: script,
                        manifestJSON: draft.draftManifestJSON
                    )
                } else if let manifest = draft.draftManifestJSON, !manifest.isEmpty {
                    _ = try await skillManager.replaceSkillManifest(
                        name: targetName,
                        manifestJSON: manifest
                    )
                }
            }

            _ = try await workflowTraceStore.updateDraftCandidateStatus(id: draft.id, status: .applied)
            return .success("Applied skill draft '\(draft.id)' to '\(metadata.name)'.")
        } catch {
            return .error("Failed to apply skill draft: \(error.localizedDescription)")
        }
    }

    private func handleDismissDraft(input: [String: Any]) async -> ToolResult {
        guard let workflowTraceStore else {
            return .error("Skill drafts are not available in this runtime.")
        }
        guard let draftID = input["draft_id"] as? String, !draftID.isEmpty else {
            return .error("Missing required parameter: draft_id")
        }

        do {
            guard let updated = try await workflowTraceStore.updateDraftCandidateStatus(
                id: draftID,
                status: .dismissed
            ) else {
                return .error("Skill draft '\(draftID)' not found.")
            }
            return .success("Dismissed skill draft '\(updated.id)'.")
        } catch {
            return .error("Failed to dismiss skill draft: \(error.localizedDescription)")
        }
    }
}
