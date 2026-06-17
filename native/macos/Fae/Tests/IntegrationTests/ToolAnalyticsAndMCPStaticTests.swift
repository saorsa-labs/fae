import XCTest
import MCP
@testable import Fae

/// Coverage for two 0%-covered files: ToolAnalytics (actor + SQLite, tested via
/// a temp DB path) and MCPToolProxy.schemaToString (pure MCP.Value→JSON encoder).
final class ToolAnalyticsAndMCPStaticTests: XCTestCase {

    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fae-ta-mcp-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeAnalytics() throws -> ToolAnalytics {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try ToolAnalytics(path: tempDir.appendingPathComponent("analytics.db").path)
    }

    // MARK: - ToolAnalytics

    func testRecordAndTotalRecords() async throws {
        let analytics = try makeAnalytics()
        await analytics.record(toolName: "read", success: true, latencyMs: 12, approved: nil, error: nil)
        await analytics.record(toolName: "read", success: false, latencyMs: 5, approved: nil, error: "boom")
        await analytics.record(toolName: "write", success: true, latencyMs: 30, approved: true, error: nil)

        let total = await analytics.totalRecords()
        XCTAssertEqual(total, 3)
    }

    func testSummaryAggregatesPerTool() async throws {
        let analytics = try makeAnalytics()
        await analytics.record(toolName: "bash", success: true, latencyMs: 100, approved: true, error: nil)
        await analytics.record(toolName: "bash", success: true, latencyMs: 200, approved: false, error: nil)
        await analytics.record(toolName: "bash", success: false, latencyMs: 50, approved: nil, error: "err")

        let summary = await analytics.summary()
        XCTAssertEqual(summary.count, 1)
        let bash = try XCTUnwrap(summary.first { $0.toolName == "bash" })
        XCTAssertEqual(bash.totalCalls, 3)
        XCTAssertEqual(bash.successCount, 2)
        XCTAssertEqual(bash.failureCount, 1)
        XCTAssertNotNil(bash.avgLatencyMs)
        // 1 approved / 2 where approved non-null
        XCTAssertNotNil(bash.approvalRate)
    }

    func testSummarySeparatesTools() async throws {
        let analytics = try makeAnalytics()
        await analytics.record(toolName: "alpha", success: true, latencyMs: 1, approved: nil, error: nil)
        await analytics.record(toolName: "beta", success: false, latencyMs: 2, approved: nil, error: nil)

        let summary = await analytics.summary()
        XCTAssertEqual(summary.count, 2)
        let names = Set(summary.map(\.toolName))
        XCTAssertEqual(names, ["alpha", "beta"])
    }

    func testSummaryEmptyWhenNoRecords() async throws {
        let analytics = try makeAnalytics()
        let summary = await analytics.summary()
        XCTAssertEqual(summary.count, 0)
        let total = await analytics.totalRecords()
        XCTAssertEqual(total, 0)
    }

    // MARK: - MCPToolProxy.schemaToString

    func testSchemaToStringString() {
        let json = MCPToolProxy.schemaToString(.string("hello"))
        XCTAssertTrue(json.contains("hello"))
    }

    func testSchemaToStringInt() {
        let json = MCPToolProxy.schemaToString(.int(42))
        XCTAssertTrue(json.contains("42"))
    }

    func testSchemaToStringBool() {
        let json = MCPToolProxy.schemaToString(.bool(true))
        XCTAssertTrue(json.contains("true") || json.contains("1"))
    }

    func testSchemaToStringObject() {
        let obj: MCP.Value = .object([
            "type": .string("string"),
            "description": .string("a field"),
        ])
        let json = MCPToolProxy.schemaToString(obj)
        XCTAssertTrue(json.contains("type"))
        XCTAssertTrue(json.contains("description"))
    }

    func testSchemaToStringArray() {
        let json = MCPToolProxy.schemaToString(.array([.int(1), .int(2)]))
        XCTAssertTrue(json.contains("1"))
        XCTAssertTrue(json.contains("2"))
    }
}
