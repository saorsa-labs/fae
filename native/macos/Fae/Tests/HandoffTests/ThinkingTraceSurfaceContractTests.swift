import XCTest
@testable import Fae

final class ThinkingTraceSurfaceContractTests: XCTestCase {
    func testSwiftThinkingTraceSurfaceIsRetiredWithLegacyConversationUI() {
        XCTAssertFalse(repositoryFileExists(relativePath: "native/macos/Fae/Sources/Fae/ConversationScrollView.swift"))
        XCTAssertFalse(repositoryFileExists(relativePath: "native/macos/Fae/Sources/Fae/ThinkingTraceViews.swift"))
    }

    func testRuntimeStillTracksThinkingTraceForOrbMirror() throws {
        let source = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/ConversationRuntimeController.swift")

        XCTAssertTrue(source.contains("@Published var streamingThinkText: String"))
        XCTAssertTrue(source.contains("@Published var completedThinkTrace: String?"))
        XCTAssertTrue(source.contains("func finalizeThinkingTrace()"))
    }

    private func loadRepositoryText(relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repositoryFileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: repositoryRoot().appendingPathComponent(relativePath).path)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
