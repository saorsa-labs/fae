import XCTest
@testable import Fae

final class WorkWithFaeWorkspaceTests: XCTestCase {
    func testScanDirectorySkipsIgnoredFoldersAndFindsRegularFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("work-with-fae-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "hello".write(to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)

        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ignored".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let results = WorkWithFaeWorkspaceStore.scanDirectory(root)
        XCTAssertTrue(results.contains(where: { $0.relativePath == "docs/guide.md" }))
        XCTAssertFalse(results.contains(where: { $0.relativePath.contains(".git") }))
    }

    func testFilteredFilesMatchesPathAndKind() {
        let files = [
            WorkWithFaeFileEntry(
                id: "/tmp/project/README.md",
                relativePath: "README.md",
                absolutePath: "/tmp/project/README.md",
                kind: "text",
                sizeBytes: 12,
                modifiedAt: nil
            ),
            WorkWithFaeFileEntry(
                id: "/tmp/project/image.png",
                relativePath: "assets/image.png",
                absolutePath: "/tmp/project/assets/image.png",
                kind: "image",
                sizeBytes: 12,
                modifiedAt: nil
            ),
        ]

        XCTAssertEqual(WorkWithFaeWorkspaceStore.filteredFiles(files, query: "readme").count, 1)
        XCTAssertEqual(WorkWithFaeWorkspaceStore.filteredFiles(files, query: "image").count, 1)
        XCTAssertEqual(WorkWithFaeWorkspaceStore.filteredFiles(files, query: "").count, 2)
    }

    func testPreparePromptKeepsLocalWorkspaceContextOnFaeLocalhost() {
        let state = WorkWithFaeWorkspaceState(
            selectedDirectoryPath: "/tmp/project",
            indexedFiles: [
                WorkWithFaeFileEntry(
                    id: "/tmp/project/README.md",
                    relativePath: "README.md",
                    absolutePath: "/tmp/project/README.md",
                    kind: "text",
                    sizeBytes: 12,
                    modifiedAt: nil
                )
            ],
            attachments: [
                WorkWithFaeAttachment(kind: .text, displayName: "note", inlineText: "Important pasted note")
            ]
        )

        let focusedPreview = WorkWithFaePreview(
            source: .workspaceFile,
            title: "README.md",
            subtitle: "Text",
            kind: "text",
            path: "/tmp/project/README.md",
            textPreview: "Project overview\nKey details"
        )

        let prepared = WorkWithFaeWorkspaceStore.preparePrompt(
            userPrompt: "Summarize this project",
            state: state,
            focusedPreview: focusedPreview
        )
        XCTAssertTrue(prepared.containsLocalOnlyContext)
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Workspace root: /tmp/project"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("README.md"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Important pasted note"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Focused item:"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Project overview"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Summarize this project"))
    }

    func testPreparePromptStripsLocalWorkspaceContextFromShareablePrompt() {
        let state = WorkWithFaeWorkspaceState(
            selectedDirectoryPath: "/tmp/project",
            indexedFiles: [
                WorkWithFaeFileEntry(
                    id: "/tmp/project/README.md",
                    relativePath: "README.md",
                    absolutePath: "/tmp/project/README.md",
                    kind: "text",
                    sizeBytes: 12,
                    modifiedAt: nil
                )
            ],
            attachments: [
                WorkWithFaeAttachment(kind: .text, displayName: "note", inlineText: "Important pasted note")
            ]
        )

        let focusedPreview = WorkWithFaePreview(
            source: .workspaceFile,
            title: "README.md",
            subtitle: "Text",
            kind: "text",
            path: "/tmp/project/README.md",
            textPreview: "Project overview\nKey details"
        )

        let prepared = WorkWithFaeWorkspaceStore.preparePrompt(
            userPrompt: "Summarize this project",
            state: state,
            focusedPreview: focusedPreview
        )
        XCTAssertFalse(prepared.shareablePrompt.contains("Workspace root: /tmp/project"))
        XCTAssertFalse(prepared.shareablePrompt.contains("Indexed files:"))
        XCTAssertFalse(prepared.shareablePrompt.contains("Project overview"))
        XCTAssertTrue(prepared.shareablePrompt.contains("Important pasted note"))
        XCTAssertTrue(prepared.shareablePrompt.contains("Summarize this project"))
    }
}
