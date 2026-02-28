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
    let scheduler: FaeScheduler
    let schedulerStore: SchedulerPersistenceStore
    let config: FaeConfig

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-integration-\(UUID().uuidString)")
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
            memoryStore: memoryStore
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

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }
}
