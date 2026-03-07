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

    func testModelDocsReflectCurrentBenchmarkDefaultOfQwen35TwoB() throws {
        let readme = try loadRepositoryText(relativePath: "README.md")
        let modelSwitchingGuide = try loadRepositoryText(relativePath: "docs/guides/model-switching.md")

        for ramGB in [8, 16, 32, 64, 128] {
            let selection = FaeConfig.recommendedModel(
                totalMemoryBytes: UInt64(ramGB) * 1024 * 1024 * 1024,
                preset: "auto"
            )
            XCTAssertEqual(selection.modelId, "mlx-community/Qwen3.5-2B-4bit")
            XCTAssertEqual(selection.contextSize, 16_384)
        }

        XCTAssertTrue(readme.contains("Qwen3.5-2B (default)"))
        XCTAssertTrue(readme.contains("`auto` currently resolves to `mlx-community/Qwen3.5-2B-4bit` on all machines"))
        XCTAssertFalse(readme.contains("Auto mode selects the LLM based on system RAM"))

        XCTAssertTrue(modelSwitchingGuide.contains("current default — presently resolves to `qwen3_5_2b` on all machines"))
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
