import XCTest
@testable import Fae

final class WorkWithFaeWorkspaceTests: XCTestCase {

    // MARK: - kindForFile

    func testKindForFileFolder() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test"), isDirectory: true), "folder")
    }

    func testKindForFileSwift() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.swift"), isDirectory: false), "text")
    }

    func testKindForFileImage() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.png"), isDirectory: false), "image")
    }

    func testKindForFilePDF() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.pdf"), isDirectory: false), "document")
    }

    func testKindForFileUnknownExt() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.xyz"), isDirectory: false), "xyz")
    }

    // MARK: - duplicatedWorkspaceName

    func testDuplicatedWorkspaceNameSimple() {
        let name = WorkWithFaeWorkspaceStore.duplicatedWorkspaceName(from: "My Workspace", existingNames: [])
        XCTAssertEqual(name, "My Workspace Fork")
    }

    func testDuplicatedWorkspaceNameConflict() {
        let name = WorkWithFaeWorkspaceStore.duplicatedWorkspaceName(from: "My Workspace", existingNames: ["my workspace fork"])
        XCTAssertEqual(name, "My Workspace Fork 2")
    }

    func testDuplicatedWorkspaceNameMultipleConflicts() {
        let name = WorkWithFaeWorkspaceStore.duplicatedWorkspaceName(from: "My Workspace", existingNames: ["my workspace fork", "my workspace fork 2"])
        XCTAssertEqual(name, "My Workspace Fork 3")
    }

    // MARK: - compressConversation

    func testCompressConversationWithinLimit() {
        let messages = (1...50).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let compressed = WorkWithFaeWorkspaceStore.compressConversation(messages, maxMessages: 120)
        XCTAssertEqual(compressed.count, 50)
    }

    func testCompressConversationOverLimit() {
        let messages = (1...200).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let compressed = WorkWithFaeWorkspaceStore.compressConversation(messages, maxMessages: 50)
        XCTAssertEqual(compressed.count, 50)
    }

    func testCompressConversationHardCap() {
        let messages = (1...600).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let compressed = WorkWithFaeWorkspaceStore.compressConversation(messages, maxMessages: 120)
        XCTAssertEqual(compressed.count, 500) // hard cap
    }

    func testCompressConversationKeepsSummary() {
        let summary = WorkWithFaeConversationMessage(id: UUID(), role: "summary", content: "compressed context")
        let messages = [summary] + (1...130).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let compressed = WorkWithFaeWorkspaceStore.compressConversation(messages, maxMessages: 120)
        XCTAssertTrue(compressed.contains { $0.role == "summary" })
    }

    // MARK: - reindexed

    func testReindexed() {
        let w1 = makeWorkspace(sortOrder: 5)
        let w2 = makeWorkspace(sortOrder: 3)
        let result = WorkWithFaeWorkspaceStore.reindexed([w1, w2])
        XCTAssertEqual(result[0].sortOrder, 0)
        XCTAssertEqual(result[1].sortOrder, 1)
    }

    func makeWorkspace(sortOrder: Int) -> WorkWithFaeWorkspaceRecord {
        WorkWithFaeWorkspaceRecord(
            id: UUID(), name: "Test",
            agentID: "agent-id", parentWorkspaceID: nil,
            sortOrder: sortOrder,
            policy: .default,
            state: .empty,
            createdAt: Date(), updatedAt: Date()
        )
    }

    // MARK: - formattedConversationHistory

    func testFormattedConversationHistory() {
        let messages = [
            WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "Hello"),
            WorkWithFaeConversationMessage(id: UUID(), role: "assistant", content: "Hi there"),
        ]
        let history = WorkWithFaeWorkspaceStore.formattedConversationHistory(from: messages)
        XCTAssertNotNil(history)
        XCTAssertTrue(history!.contains("Hello"))
    }

    func testFormattedConversationHistoryEmpty() {
        let history = WorkWithFaeWorkspaceStore.formattedConversationHistory(from: [])
        XCTAssertNil(history)
    }

    func testFormattedConversationHistoryIncludesSummary() {
        let messages = [
            WorkWithFaeConversationMessage(id: UUID(), role: "summary", content: "compressed context"),
        ] + (1...20).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let history = WorkWithFaeWorkspaceStore.formattedConversationHistory(from: messages, limit: 5)
        XCTAssertNotNil(history)
        XCTAssertTrue(history!.contains("compressed context"))
    }

    // MARK: - attachmentHandle

    func testAttachmentHandleTitle() {
        let handle = WorkWithFaeWorkspaceStore.attachmentHandle(for: "My Document", fallback: "")
        XCTAssertEqual(handle, "attachment-my-document")
    }

    func testAttachmentHandleFallback() {
        let handle = WorkWithFaeWorkspaceStore.attachmentHandle(for: "", fallback: "ABC123")
        XCTAssertEqual(handle, "attachment-abc123")
    }

    func testAttachmentHandleBothEmpty() {
        let handle = WorkWithFaeWorkspaceStore.attachmentHandle(for: "", fallback: "")
        XCTAssertEqual(handle, "attachment")
    }

    // MARK: - deduplicatedTransforms

    func testDeduplicatedTransforms() {
        let transforms: [CoworkExportTransform] = [.trimmed, .trimmed, .truncated]
        let result = WorkWithFaeWorkspaceStore.deduplicatedTransforms(transforms)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - sanitizedConversationState

    func testSanitizedConversationStateTruncatesLong() {
        var state = WorkWithFaeWorkspaceState.empty
        state.conversationMessages = (1...600).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let sanitized = WorkWithFaeWorkspaceStore.sanitizedConversationState(state)
        XCTAssertLessThanOrEqual(sanitized.conversationMessages.count, 500)
    }

    func testSanitizedConversationStateShort() {
        var state = WorkWithFaeWorkspaceState.empty
        state.conversationMessages = (1...10).map { WorkWithFaeConversationMessage(id: UUID(), role: "user", content: "msg \($0)") }
        let sanitized = WorkWithFaeWorkspaceStore.sanitizedConversationState(state)
        XCTAssertEqual(sanitized.conversationMessages.count, 10)
    }

    // MARK: - appendUnique

    func testAppendUnique() {
        var values: [String] = ["a", "b"]
        WorkWithFaeWorkspaceStore.appendUnique("c", to: &values)
        XCTAssertEqual(values, ["a", "b", "c"])
    }

    func testAppendUniqueDuplicate() {
        var values: [String] = ["a", "b"]
        WorkWithFaeWorkspaceStore.appendUnique("a", to: &values)
        XCTAssertEqual(values, ["a", "b"])
    }
}
