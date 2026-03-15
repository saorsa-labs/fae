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

        XCTAssertEqual(registry.allTools.count, 34)
        XCTAssertEqual(readOnlyCount, 16)
        XCTAssertEqual(readWriteCount, 32)
        XCTAssertEqual(fullCount, 34)

        XCTAssertTrue(guide.contains("Total: 34 tools"))
        XCTAssertTrue(guide.contains("read_only`: 16 tools") || guide.contains("`read_only`: 16 tools"))
        XCTAssertTrue(guide.contains("read_write`: 32 tools") || guide.contains("`read_write`: 32 tools"))
        XCTAssertTrue(guide.contains("full` / `full_no_approval`: 34 tools") || guide.contains("`full` / `full_no_approval`: 34 tools"))
        XCTAssertTrue(guide.contains("delegate_agent"))
        XCTAssertTrue(guide.contains("FaeScheduler.triggerTask(id:)"))

        let builtinTaskIDs = [
            "memory_reflect", "memory_reindex", "memory_migrate", "memory_gc", "memory_backup",
            "memory_inbox_ingest", "memory_digest",
            "check_fae_update", "noise_budget_reset", "stale_relationships", "morning_briefing",
            "skill_proposals", "skill_distill", "skill_health_check", "vault_backup", "camera_presence_check",
            "screen_activity_check", "overnight_work", "embedding_reindex", "enhanced_morning_briefing",
        ]

        for taskID in builtinTaskIDs {
            XCTAssertTrue(guide.contains("`\(taskID)`"), "Scheduler guide is missing builtin task: \(taskID)")
        }
    }

    func testModelDocsReflectCurrentAutoOperatorPolicy() throws {
        let readme = try loadRepositoryText(relativePath: "README.md")
        let modelSwitchingGuide = try loadRepositoryText(relativePath: "docs/guides/model-switching.md")
        // Auto policy: <16 GB → saorsa-1.1-tiny, 16–31 GB → 4B, 32–63 GB → 27B@32K, 64+ GB → 27B@128K
        let expectations: [(Int, String, Int)] = [
            (8, "saorsa-labs/saorsa-1.1-tiny", 32_768),
            (16, "mlx-community/Qwen3.5-4B-4bit", 32_768),
            (32, "mlx-community/Qwen3.5-27B-4bit", 32_768),
            (64, "mlx-community/Qwen3.5-27B-4bit", 131_072),
            (128, "mlx-community/Qwen3.5-27B-4bit", 131_072),
        ]

        for (ramGB, modelId, contextSize) in expectations {
            let selection = FaeConfig.recommendedModel(
                totalMemoryBytes: UInt64(ramGB) * 1024 * 1024 * 1024,
                preset: "auto"
            )
            XCTAssertEqual(selection.modelId, modelId)
            XCTAssertEqual(selection.contextSize, contextSize)
        }

        XCTAssertTrue(readme.contains("Qwen3.5 single-model local stack"))
        XCTAssertTrue(readme.contains("`<16 GB`: `saorsa-1.1-tiny`"))
        XCTAssertTrue(readme.contains("`16–31 GB`: `Qwen3.5 4B`"))
        XCTAssertTrue(readme.contains("`32–63 GB`: `Qwen3.5 27B`"))
        XCTAssertTrue(readme.contains("`64+ GB`: `Qwen3.5 27B`"))

        XCTAssertTrue(modelSwitchingGuide.contains("`Auto (Recommended)` resolves by RAM"))
        XCTAssertTrue(modelSwitchingGuide.contains("`<16 GB` | `saorsa-1.1-tiny`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`16–31 GB` | `Qwen3.5 4B`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`32–63 GB` | `Qwen3.5 27B`"))
        XCTAssertTrue(modelSwitchingGuide.contains("`64+ GB` | `Qwen3.5 27B`"))
        XCTAssertTrue(modelSwitchingGuide.contains("one active Qwen3.5 text model"))
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
