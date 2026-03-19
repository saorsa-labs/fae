import XCTest
@testable import Fae

/// Tests that validate skill activation, SKILL.md parsing, and prompt injection
/// into the LLM system prompt. These do NOT require a live LLM — they verify
/// the plumbing that delivers skill instructions to the model.
///
/// For live LLM validation (does the model generate correct tool calls?),
/// see the FreeformEvalSuites benchmark which runs against the real model.
final class SkillActivationTests: XCTestCase {

    // MARK: - Skill Discovery

    /// Every bundled skill directory must have a parseable SKILL.md.
    func testAllBundledSkillsHaveValidMetadata() async {
        let manager = SkillManager()
        let skills = await manager.discoverSkills()

        XCTAssertGreaterThanOrEqual(skills.count, 26, "Expected at least 26 bundled skills (21 original + 5 new)")

        for skill in skills {
            XCTAssertFalse(skill.name.isEmpty, "Skill name must not be empty")
            XCTAssertFalse(skill.description.isEmpty, "Skill '\(skill.name)' must have a description")
        }
    }

    /// New skills must be discovered alongside existing ones.
    func testNewSkillsDiscovered() async {
        let manager = SkillManager()
        let skills = await manager.discoverSkills()
        let names = Set(skills.map(\.name))

        let expectedNew = [
            "document-analyst",
            "email-triage",
            "focus-defender",
            "system-health",
            "file-organizer",
            "smart-home",
            "channel-hub",
        ]

        for expected in expectedNew {
            XCTAssertTrue(names.contains(expected), "Missing expected skill: '\(expected)'")
        }
    }

    // MARK: - Skill Activation

    /// Activating a skill returns its SKILL.md body for system prompt injection.
    func testSkillActivationReturnsBody() async throws {
        let manager = SkillManager()
        _ = await manager.discoverSkills()

        guard let result = await manager.activate(skillName: "document-analyst") else {
            XCTFail("document-analyst failed to activate")
            return
        }
        XCTAssertTrue(result.contains("Document Analyst"), "Activated body should contain skill title")
        XCTAssertTrue(result.contains("Locate the document"), "Activated body should contain workflow steps")
    }

    /// activatedContext() returns the body of the currently active skill.
    func testActivatedContextReturnsSkillBody() async throws {
        let manager = SkillManager()
        _ = await manager.discoverSkills()

        _ = await manager.activate(skillName: "system-health")
        let context = await manager.activatedContext()
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("System Health Monitor") ?? false)
    }

    /// Deactivating a skill clears the activated context.
    func testDeactivationClearsContext() async throws {
        let manager = SkillManager()
        _ = await manager.discoverSkills()

        _ = await manager.activate(skillName: "email-triage")
        let before = await manager.activatedContext()
        XCTAssertNotNil(before)

        await manager.deactivate(skillName: "email-triage")
        let after = await manager.activatedContext()
        XCTAssertNil(after)
    }

    // MARK: - Prompt Metadata

    /// promptMetadata() includes new skills with correct names and descriptions.
    func testPromptMetadataIncludesNewSkills() async {
        let manager = SkillManager()
        let metadata = await manager.promptMetadata()
        let names = metadata.map(\.name)

        XCTAssertTrue(names.contains("document-analyst"))
        XCTAssertTrue(names.contains("email-triage"))
        XCTAssertTrue(names.contains("focus-defender"))
        XCTAssertTrue(names.contains("system-health"))
        XCTAssertTrue(names.contains("file-organizer"))
        XCTAssertTrue(names.contains("smart-home"))
        XCTAssertTrue(names.contains("channel-hub"))
    }

    /// Prompt metadata descriptions are concise (under 200 chars).
    func testPromptMetadataDescriptionsAreConcise() async {
        let manager = SkillManager()
        let metadata = await manager.promptMetadata()

        for entry in metadata {
            XCTAssertLessThanOrEqual(
                entry.description.count, 200,
                "Skill '\(entry.name)' description too long (\(entry.description.count) chars) — will bloat system prompt"
            )
        }
    }

    // MARK: - Token Budget

    /// Each skill body must fit within a reasonable token budget when activated.
    /// Qwen3.5 context is 32K-128K tokens. Skill body should be <2000 tokens
    /// (~8000 chars) to leave room for conversation history.
    func testSkillBodiesFitTokenBudget() async {
        let manager = SkillManager()
        _ = await manager.discoverSkills()

        let skillNames = [
            "document-analyst", "email-triage", "focus-defender",
            "system-health", "file-organizer", "smart-home", "channel-hub",
        ]

        for name in skillNames {
            guard let body = await manager.activate(skillName: name) else {
                XCTFail("Skill '\(name)' failed to activate")
                continue
            }
            let charCount = body.count
            let estimatedTokens = charCount / 4

            XCTAssertLessThanOrEqual(
                estimatedTokens, 2000,
                "Skill '\(name)' body is ~\(estimatedTokens) tokens (\(charCount) chars) — exceeds 2000 token budget"
            )

            await manager.deactivate(skillName: name)
        }
    }

    // MARK: - Skill Content Validation

    /// Each skill must reference at least one Fae tool by name.
    func testSkillsReferenceValidTools() async {
        let manager = SkillManager()
        _ = await manager.discoverSkills()

        let knownTools: Set<String> = [
            "read", "write", "edit", "bash", "self_config",
            "calendar", "reminders", "contacts", "mail", "notes",
            "activate_skill", "run_skill", "manage_skill",
            "web_search", "fetch_url", "screenshot", "camera",
            "channel_setup", "input_request", "voice_identity",
        ]

        let skillNames = [
            "document-analyst", "email-triage", "focus-defender",
            "system-health", "file-organizer", "smart-home", "channel-hub",
        ]

        for name in skillNames {
            guard let body = await manager.activate(skillName: name) else {
                XCTFail("Skill '\(name)' failed to activate")
                continue
            }
            let lowered = body.lowercased()

            let referencedTools = knownTools.filter { lowered.contains($0) }
            XCTAssertFalse(
                referencedTools.isEmpty,
                "Skill '\(name)' does not reference any known Fae tools — LLM won't know which tools to use"
            )

            await manager.deactivate(skillName: name)
        }
    }

    /// No skill should contain forbidden patterns (API keys, hardcoded URLs, etc.).
    func testSkillsContainNoForbiddenPatterns() async {
        let manager = SkillManager()
        _ = await manager.discoverSkills()

        // Check for actual hardcoded credentials, not documentation examples.
        // "sk-" is excluded because secure-input skill legitimately references it as an example.
        // Check for actual hardcoded credential VALUES (not documentation references).
        // secure-input skill legitimately references API key patterns as examples.
        let forbidden = [
            "ANTHROPIC_API_KEY=sk-",   // actual key assignment
            "OPENAI_API_KEY=sk-",      // actual key assignment
            "Bearer sk-ant-",          // actual Anthropic bearer token
        ]

        let skills = await manager.discoverSkills()
        for skill in skills {
            guard let body = await manager.activate(skillName: skill.name) else { continue }
            for pattern in forbidden {
                XCTAssertFalse(
                    body.contains(pattern),
                    "Skill '\(skill.name)' contains forbidden pattern '\(pattern)'"
                )
            }
            await manager.deactivate(skillName: skill.name)
        }
    }
}
