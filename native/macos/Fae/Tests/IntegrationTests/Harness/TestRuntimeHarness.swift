import Foundation
import GRDB
@testable import Fae

/// Creates a fully-wired test environment with mock engines, real SQLite stores,
/// and event collection. Used by all end-to-end integration tests.
///
/// Since PipelineCoordinator requires concrete ML engine types and audio hardware,
/// integration tests exercise the component layer directly: memory orchestrator,
/// scheduler, tool registry, risk policies, and event bus.
final class TestRuntimeHarness: @unchecked Sendable {
    let eventBus: FaeEventBus
    let eventCollector: EventCollector
    let memoryStore: SQLiteMemoryStore
    let memoryOrchestrator: MemoryOrchestrator
    let workflowTraceStore: WorkflowTraceStore
    let scheduler: FaeScheduler
    let schedulerStore: SchedulerPersistenceStore
    let config: FaeConfig

    /// Real GRDB-backed receipt store for integration tests.
    let receiptStore: ReceiptStore

    /// Temporary directory (unique per test run, deleted in cleanup()).
    let tmpDir: URL

    init() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-integration-\(UUID().uuidString)")
        self.tmpDir = tmpDir
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Config with memory enabled.
        var cfg = FaeConfig()
        cfg.memory.enabled = true
        cfg.memory.maxRecallResults = 5
        cfg.speaker.requireOwnerForTools = true
        self.config = cfg

        // Event bus + collector.
        eventBus = FaeEventBus()
        eventCollector = EventCollector()

        // Real SQLite memory store.
        memoryStore = try SQLiteMemoryStore(
            path: tmpDir.appendingPathComponent("fae.db").path
        )
        let workflowDBQueue = try DatabaseQueue(path: tmpDir.appendingPathComponent("fae.db").path)
        _ = try SessionStore(dbQueue: workflowDBQueue)
        workflowTraceStore = try WorkflowTraceStore(dbQueue: workflowDBQueue)

        // Memory orchestrator.
        memoryOrchestrator = MemoryOrchestrator(
            store: memoryStore,
            config: cfg.memory
        )

        // Scheduler persistence store.
        schedulerStore = try SchedulerPersistenceStore(
            path: tmpDir.appendingPathComponent("scheduler.db").path
        )

        // Scheduler with memory wiring.
        scheduler = FaeScheduler(
            eventBus: eventBus,
            memoryOrchestrator: memoryOrchestrator,
            memoryStore: memoryStore,
            workflowTraceStore: workflowTraceStore
        )

        // Real receipt store backed by a separate SQLite DB.
        receiptStore = try ReceiptStore(
            path: tmpDir.appendingPathComponent("receipts.db").path
        )
    }

    /// Wire up event collector and scheduler persistence.
    func setUp() async {
        await eventCollector.start(bus: eventBus)
        await scheduler.configurePersistence(store: schedulerStore)
    }

    /// Build a ToolRegistry with the given tools (or default mocks).
    func makeRegistry(tools: [any Tool]? = nil) -> ToolRegistry {
        if let tools {
            return ToolRegistry(tools: tools)
        }
        return ToolRegistry(tools: [
            MockTool(name: "read", riskLevel: .low, requiresApproval: false),
            MockTool(name: "write", riskLevel: .medium, requiresApproval: false),
            MockTool(name: "bash", riskLevel: .high, requiresApproval: true),
        ])
    }

    /// Build a DefaultTrustedActionBroker with the given owner flag.
    ///
    /// The returned broker knows all standard tools and uses the harness config's
    /// speaker settings. Pass `isOwner: true` to simulate the enrolled primary user.
    /// Note: `isOwner` flows through `ActionIntent`, not broker construction — this
    /// parameter is accepted for readability but does not affect the broker itself.
    func makeBroker(isOwner: Bool = true) -> DefaultTrustedActionBroker {
        _ = isOwner
        return DefaultTrustedActionBroker(
            knownTools: Self.standardKnownTools,
            speakerConfig: config.speaker
        )
    }

    /// All tool names recognized by the default broker policy.
    static let standardKnownTools: Set<String> = [
        "read", "write", "edit", "bash", "self_config",
        "session_search", "web_search", "fetch_url", "input_request",
        "activate_skill", "run_skill", "manage_skill",
        "delegate_agent", "agent_session",
        "channel_setup",
        "calendar", "reminders", "contacts", "mail", "notes",
        "scheduler_list", "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger",
        "roleplay",
        "screenshot", "camera", "read_screen",
        "click", "type_text", "scroll", "find_element",
        "voice_identity",
        "till_done", "window_control",
        "plugin_manage",
    ]

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }
}
