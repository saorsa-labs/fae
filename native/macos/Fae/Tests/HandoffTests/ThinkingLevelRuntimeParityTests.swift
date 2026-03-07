import Foundation
import XCTest
@testable import Fae

final class ThinkingLevelRuntimeParityTests: XCTestCase {
    @MainActor
    func testFaeCoreSetThinkingMethodsKeepPublishedStateAndConfigInSync() async throws {
        let url = FaeConfig.configFileURL
        let fm = FileManager.default
        let original = try? Data(contentsOf: url)

        defer {
            if let original {
                try? original.write(to: url, options: .atomic)
            } else {
                try? fm.removeItem(at: url)
            }
        }

        let core = FaeCore()

        core.setThinkingLevel(.deep)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(core.thinkingLevel, .deep)
        XCTAssertTrue(core.thinkingEnabled)

        core.setThinkingEnabled(false)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(core.thinkingLevel, .fast)
        XCTAssertFalse(core.thinkingEnabled)

        core.cycleThinkingLevel()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(core.thinkingLevel, .balanced)
        XCTAssertTrue(core.thinkingEnabled)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.llm.resolvedThinkingLevel, .balanced)
        XCTAssertTrue(reloaded.llm.thinkingEnabled)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "thinkingLevel"), FaeThinkingLevel.balanced.rawValue)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "thinkingEnabled") as? Bool, true)
    }

    func testThinkingLevelControlsRemainWiredAcrossMainAndCoworkSurfaces() throws {
        let settingsModels = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/SettingsModelsTab.swift")
        let settingsPerformance = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/SettingsModelsPerformanceTab.swift")
        let inputBar = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/InputBarView.swift")
        let coworkView = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceView.swift")

        XCTAssertTrue(settingsModels.contains("Picker(\"Thinking level\""))
        XCTAssertTrue(settingsModels.contains("payload: [\"key\": \"llm.thinking_level\""))
        XCTAssertTrue(settingsPerformance.contains("Picker(\"Thinking level\""))
        XCTAssertTrue(settingsPerformance.contains("patchConfig(\"llm.thinking_level\""))
        XCTAssertTrue(inputBar.contains("faeCore.setThinkingLevel(level)"))
        XCTAssertTrue(inputBar.contains("Text(faeCore.thinkingLevel.displayName)"))
        XCTAssertTrue(coworkView.contains("controller.setThinkingLevel(level)"))
        XCTAssertTrue(coworkView.contains("conversationControlPill(icon: faeCore.thinkingLevel.systemImage, title: faeCore.thinkingLevel.displayName)"))
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
