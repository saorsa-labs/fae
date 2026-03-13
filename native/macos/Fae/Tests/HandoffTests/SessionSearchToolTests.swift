import XCTest
@testable import Fae

final class SessionSearchToolTests: XCTestCase {

    private func makeStore() async throws -> SessionStore {
        let dbPath = "\(NSTemporaryDirectory())/session-search-tool-test-\(UUID().uuidString).sqlite"
        let memoryStore = try SQLiteMemoryStore(path: dbPath)
        return try await SessionStore(dbQueue: memoryStore.sharedDatabaseQueue)
    }

    func testExecuteFormatsSessionMatches() async throws {
        let store = try await makeStore()
        let startedAt = Date().addingTimeInterval(-300)
        let session = try await store.openSession(kind: .main, speakerId: "owner", startedAt: startedAt)
        _ = try await store.appendMessage(
            sessionId: session.id,
            turnId: "turn-1",
            role: .user,
            content: "Please keep the launch checklist handy.",
            speakerId: "owner",
            createdAt: startedAt
        )
        _ = try await store.appendMessage(
            sessionId: session.id,
            turnId: "turn-1",
            role: .assistant,
            content: "The launch checklist is still in our notes from earlier.",
            createdAt: startedAt.addingTimeInterval(1)
        )
        try await store.closeSession(id: session.id, endedAt: startedAt.addingTimeInterval(3))

        let tool = SessionSearchTool(sessionStore: store)
        let result = try await tool.execute(input: ["query": "launch checklist", "limit": 1])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Session 1"))
        XCTAssertTrue(result.output.contains(session.id))
        XCTAssertTrue(result.output.contains("launch checklist"))
    }

    func testExecuteReturnsErrorWhenStoreUnavailable() async throws {
        let tool = SessionSearchTool(sessionStore: nil)
        let result = try await tool.execute(input: ["query": "anything"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not initialized"))
    }
}
