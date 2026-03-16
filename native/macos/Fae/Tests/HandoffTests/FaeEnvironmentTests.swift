import XCTest
@testable import Fae

final class FaeEnvironmentTests: XCTestCase {

    // MARK: - FaeDirectories Path Isolation

    func testRootDirectoryContainsFaeOrFaeDev() {
        let path = FaeDirectories.root.path
        // Must end with either /fae or /fae-dev
        XCTAssertTrue(
            path.hasSuffix("/fae") || path.hasSuffix("/fae-dev"),
            "Root directory should end with /fae or /fae-dev, got: \(path)"
        )
    }

    func testVaultDirectoryContainsFaeVaultOrFaeVaultDev() {
        let path = FaeDirectories.vault.path
        XCTAssertTrue(
            path.hasSuffix("/.fae-vault") || path.hasSuffix("/.fae-vault-dev"),
            "Vault directory should end with /.fae-vault or /.fae-vault-dev, got: \(path)"
        )
    }

    func testAllFilePathsLiveUnderRoot() {
        let root = FaeDirectories.root.path
        let files: [URL] = [
            FaeDirectories.configFile,
            FaeDirectories.soulFile,
            FaeDirectories.directiveFile,
            FaeDirectories.heartbeatFile,
            FaeDirectories.database,
            FaeDirectories.schedulerDatabase,
            FaeDirectories.toolAnalyticsDatabase,
            FaeDirectories.speakersFile,
            FaeDirectories.wakeLexiconFile,
            FaeDirectories.approvedToolsFile,
            FaeDirectories.securityEventsFile,
            FaeDirectories.novelRecipientsFile,
            FaeDirectories.roleplaySessionsFile,
            FaeDirectories.roleplayVoicesFile,
        ]

        for file in files {
            XCTAssertTrue(
                file.path.hasPrefix(root),
                "\(file.lastPathComponent) should be under root \(root), got: \(file.path)"
            )
        }
    }

    func testAllSubdirectoriesLiveUnderRoot() {
        let root = FaeDirectories.root.path
        let dirs: [URL] = [
            FaeDirectories.skillsDirectory,
            FaeDirectories.voicesDirectory,
            FaeDirectories.recoveryDirectory,
            FaeDirectories.modelsDirectory,
            FaeDirectories.inboxDirectory,
        ]

        for dir in dirs {
            XCTAssertTrue(
                dir.path.hasPrefix(root),
                "\(dir.lastPathComponent) should be under root \(root), got: \(dir.path)"
            )
        }
    }

    func testVaultPathSuffixMatchesEnvironment() {
        if FaeEnvironment.isDev || FaeEnvironment.isTesting {
            XCTAssertEqual(FaeDirectories.vaultBlockedPathSuffix, "/.fae-vault-dev")
        } else {
            XCTAssertEqual(FaeDirectories.vaultBlockedPathSuffix, "/.fae-vault")
        }
    }

    // MARK: - Config File Paths

    func testConfigFileIsToml() {
        XCTAssertEqual(FaeDirectories.configFile.pathExtension, "toml")
        XCTAssertEqual(FaeDirectories.configFile.lastPathComponent, "config.toml")
    }

    func testDatabasePathsEndWithDb() {
        XCTAssertEqual(FaeDirectories.database.pathExtension, "db")
        XCTAssertEqual(FaeDirectories.schedulerDatabase.pathExtension, "db")
        XCTAssertEqual(FaeDirectories.toolAnalyticsDatabase.pathExtension, "db")
    }

    // MARK: - Dev vs Prod Path Separation

    func testDevAndTestPathsUseFaeDev() {
        // Tests and dev mode both use fae-dev to avoid polluting production data
        let rootPath = FaeDirectories.root.path
        if FaeEnvironment.isDev || FaeEnvironment.isTesting {
            XCTAssertTrue(rootPath.contains("fae-dev"))
        } else {
            XCTAssertTrue(rootPath.hasSuffix("/fae"))
        }
    }

    // MARK: - FaeEnvironment Defaults

    func testDefaultsStoreIsNotNil() {
        // The defaults store should always be available
        XCTAssertNotNil(FaeEnvironment.defaults)
    }

    func testModeNameMatchesIsDev() {
        if FaeEnvironment.isDev {
            XCTAssertEqual(FaeEnvironment.modeName, "Development")
        } else {
            XCTAssertEqual(FaeEnvironment.modeName, "Production")
        }
    }

    // MARK: - FaeConfig Dev-Only Loading

    func testConfigLoadFromExplicitURLReturnsDefaultsForMissingFile() {
        // Loading from a non-existent file should return pure code defaults
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-nonexistent-\(UUID().uuidString)/config.toml")
        let config = FaeConfig.load(from: url)
        let defaults = FaeConfig()
        XCTAssertEqual(config.llm.temperature, defaults.llm.temperature)
        XCTAssertEqual(config.tts.speed, defaults.tts.speed)
        XCTAssertEqual(config.bargeIn.minRms, defaults.bargeIn.minRms)
    }

    func testConfigSaveWritesInDevOrTestMode() throws {
        // In dev or test mode, save() should write to config.toml.
        // In production mode (neither isDev nor isTesting), save() is a no-op.
        // Since tests always have isTesting=true, we verify save writes successfully.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-save-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configURL = tmpDir.appendingPathComponent("config.toml")
        var config = FaeConfig()
        config.llm.temperature = 0.42
        try config.save(to: configURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        let reloaded = FaeConfig.load(from: configURL)
        XCTAssertEqual(reloaded.llm.temperature, 0.42, accuracy: 0.001)
    }

    // MARK: - Cache Directory

    func testCacheDirectoryIsSeparateFromRoot() {
        let rootPath = FaeDirectories.root.path
        let cachePath = FaeDirectories.cache.path
        XCTAssertFalse(cachePath.hasPrefix(rootPath), "Cache should not be under the main data root")
        XCTAssertTrue(cachePath.contains("Caches"), "Cache should be under Library/Caches")
    }
}
