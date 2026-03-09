import XCTest
@testable import Fae

final class DocsContractTests: XCTestCase {
    func testMemoryGuideMatchesCurrentMemoryKindsStatusesAndStorageContract() throws {
        let guide = try loadRepositoryText(relativePath: "docs/guides/Memory.md")

        XCTAssertTrue(guide.contains("~/Library/Application Support/fae/fae.db"))
        XCTAssertTrue(guide.contains("~/Library/Application Support/fae/backups/"))

        for kind in MemoryKind.allCases.map(\.rawValue) {
            XCTAssertTrue(guide.contains("`\(kind)`"), "Memory guide is missing kind: \(kind)")
        }

        let statuses = [
            MemoryStatus.active.rawValue,
            MemoryStatus.superseded.rawValue,
            MemoryStatus.invalidated.rawValue,
            MemoryStatus.forgotten.rawValue,
        ]
        for status in statuses {
            XCTAssertTrue(guide.contains("`\(status)`"), "Memory guide is missing status: \(status)")
        }

        XCTAssertTrue(guide.contains("60% ANN"))
        XCTAssertTrue(guide.contains("40% FTS5"))
        XCTAssertTrue(guide.contains("MemoryOrchestrator.capture(...)") || guide.contains("MemoryOrchestrator.capture"))
    }

    func testSchedulerAndToolingGuideMatchesCurrentRegistryAndBuiltinTaskSurface() throws {
        let guide = try loadRepositoryText(relativePath: "docs/testing-guide/scheduler-and-tools.md")
        let registry = ToolRegistry.buildDefault()

        let readOnlyCount = registry.toolNames.filter { registry.isToolAllowed($0, mode: "read_only") }.count
        let readWriteCount = registry.toolNames.filter { registry.isToolAllowed($0, mode: "read_write") }.count
        let fullCount = registry.toolNames.filter { registry.isToolAllowed($0, mode: "full") }.count

        XCTAssertEqual(registry.allTools.count, 33)
        XCTAssertEqual(readOnlyCount, 15)
        XCTAssertEqual(readWriteCount, 31)
        XCTAssertEqual(fullCount, 33)

        XCTAssertTrue(guide.contains("Total: 33 tools"))
        XCTAssertTrue(guide.contains("read_only`: 15 tools") || guide.contains("`read_only`: 15 tools"))
        XCTAssertTrue(guide.contains("read_write`: 31 tools") || guide.contains("`read_write`: 31 tools"))
        XCTAssertTrue(guide.contains("full` / `full_no_approval`: 33 tools") || guide.contains("`full` / `full_no_approval`: 33 tools"))
        XCTAssertTrue(guide.contains("delegate_agent"))
        XCTAssertTrue(guide.contains("FaeScheduler.triggerTask(id:)"))

        let builtinTaskIDs = [
            "memory_reflect", "memory_reindex", "memory_migrate", "memory_gc", "memory_backup",
            "check_fae_update", "noise_budget_reset", "stale_relationships", "morning_briefing",
            "skill_proposals", "skill_health_check", "vault_backup", "camera_presence_check",
            "screen_activity_check", "overnight_work", "embedding_reindex", "enhanced_morning_briefing",
        ]

        for taskID in builtinTaskIDs {
            XCTAssertTrue(guide.contains("`\(taskID)`"), "Scheduler guide is missing builtin task: \(taskID)")
        }
    }

    func testModelDocsReflectCurrentAutoOperatorPolicy() throws {
        let readme = try loadRepositoryText(relativePath: "README.md")
        let modelSwitchingGuide = try loadRepositoryText(relativePath: "docs/guides/model-switching.md")
        let expectations: [(Int, String, Int)] = [
            (8, "mlx-community/Qwen3.5-0.8B-4bit", 8_192),
            (16, "mlx-community/Qwen3.5-2B-4bit", 16_384),
            (32, "mlx-community/Qwen3.5-2B-4bit", 16_384),
            (64, "mlx-community/Qwen3.5-2B-4bit", 16_384),
            (128, "mlx-community/Qwen3.5-2B-4bit", 16_384),
        ]

        for (ramGB, modelId, contextSize) in expectations {
            let selection = FaeConfig.recommendedModel(
                totalMemoryBytes: UInt64(ramGB) * 1024 * 1024 * 1024,
                preset: "auto"
            )
            XCTAssertEqual(selection.modelId, modelId)
            XCTAssertEqual(selection.contextSize, contextSize)
        }

        XCTAssertTrue(readme.contains("Benchmark-backed Qwen3.5 operator"))
        XCTAssertTrue(readme.contains("benchmark-backed operator policy"))
        XCTAssertTrue(readme.contains("12+ GB: `mlx-community/Qwen3.5-2B-4bit`"))
        XCTAssertTrue(readme.contains("below 12 GB: `mlx-community/Qwen3.5-0.8B-4bit`"))

        XCTAssertTrue(modelSwitchingGuide.contains("benchmark-backed operator policy"))
        XCTAssertTrue(modelSwitchingGuide.contains("12+ GB: `qwen3_5_2b` at 16K context"))
        XCTAssertTrue(modelSwitchingGuide.contains("below 12 GB: `qwen3_5_0_8b` at 8K context"))
        XCTAssertTrue(modelSwitchingGuide.contains("`qwen3_5_35b_a3b`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`qwen3_5_27b`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`qwen3_5_9b`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`qwen3_5_4b`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`qwen3_5_2b`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`qwen3_5_0_8b`"))
    }

    func testAdversarialSecurityPlanKeepsCriticalCoverageAreasDocumented() throws {
        let plan = try loadRepositoryText(relativePath: "docs/tests/adversarial-security-suite-plan.md")

        for heading in [
            "## A. Prompt-injection pressure",
            "## B. Filesystem abuse",
            "## C. Network abuse / SSRF-like targets",
            "## D. Skill abuse",
            "## E. Safe executor containment",
            "## F. Relay abuse",
            "## G. Approval and outbound behavior",
        ] {
            XCTAssertTrue(plan.contains(heading), "Security plan is missing heading: \(heading)")
        }

        XCTAssertTrue(plan.contains("novel recipient requires confirm"))
        XCTAssertTrue(plan.contains("sensitive outbound payload is denied"))
        XCTAssertTrue(plan.contains("Missing approval manager path"))
        XCTAssertTrue(plan.contains("localhost targets"))
        XCTAssertTrue(plan.contains("cloud metadata endpoints"))
        XCTAssertTrue(plan.contains("missing capability ticket denied"))
    }

    func testUserSecurityBehaviorContractPreservesPopupFirstAndScopedApprovalPromises() throws {
        let contract = try loadRepositoryText(relativePath: "docs/guides/user-security-behavior-contract.md")

        XCTAssertTrue(contract.contains("present the approval popup as the primary path"))
        XCTAssertTrue(contract.contains("Settings remain available for review and revocation, not as the first resort."))
        XCTAssertTrue(contract.contains("Allow All In Current Mode"))
        XCTAssertTrue(contract.contains("it does not silently escalate raw capability beyond the selected mode"))
        XCTAssertTrue(contract.contains("Advanced controls exist, but safe defaults are built in even if you never open settings."))
    }

    func testSecurityBoundaryAndPermissionGuidesReflectCurrentEnforcementStory() throws {
        let boundaryGuide = try loadRepositoryText(relativePath: "docs/guides/security-autonomy-boundary-and-execution-plan.md")
        let schedulerGuide = try loadRepositoryText(relativePath: "docs/guides/scheduler-tooling-and-permissions.md")
        let confirmationCopy = try loadRepositoryText(relativePath: "docs/guides/security-confirmation-copy.md")

        XCTAssertTrue(boundaryGuide.contains("single broker chokepoint"))
        XCTAssertTrue(boundaryGuide.contains("Default-deny on uncovered action shapes"))
        XCTAssertTrue(boundaryGuide.contains("Credentials out of untrusted execution contexts") || boundaryGuide.contains("Keep credentials out of untrusted execution contexts."))
        XCTAssertTrue(boundaryGuide.contains("Skills may request behavior. Core code grants, transforms, confirms, or denies."))

        XCTAssertTrue(schedulerGuide.lowercased().contains("prefer asking fae conversationally for setup/changes over manual config editing"))
        XCTAssertTrue(schedulerGuide.contains("Apple tool (CalendarTool, RemindersTool, ContactsTool, MailTool, NotesTool)"))
        XCTAssertTrue(schedulerGuide.contains("Tool execution in pipeline uses layered checks:"))

        XCTAssertTrue(confirmationCopy.contains("Say yes or no, or press the Yes/No button."))
        XCTAssertTrue(confirmationCopy.contains("Never mention internal terms (broker, policy engine, invariant IDs)."))
    }

    private func loadRepositoryText(relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
