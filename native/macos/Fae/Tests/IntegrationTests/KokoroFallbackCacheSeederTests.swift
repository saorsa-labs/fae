import Foundation
import XCTest

@testable import Fae

/// Unit tests for the #4 B-plus fallback-TTS cache seeder. The "no network"
/// guarantee is by construction: `seedIfNeeded()` materialises the exact dir
/// mlx-audio-swift's `resolveOrDownloadModel` checks FIRST (it returns before
/// `downloadSnapshot`). These tests pin (a) the HF cache-root resolution under
/// each env override and (b) the copy + idempotency + graceful-failure logic.
final class KokoroFallbackCacheSeederTests: XCTestCase {

    // MARK: - hubCacheRoot resolution (mirrors swift-huggingface CacheLocationProvider)

    func testHubCacheRootHonorsHFHubCacheOverride() {
        let url = KokoroFallbackCacheSeeder.hubCacheRoot(
            env: ["HF_HUB_CACHE": "/custom/cache"], homeDirectory: "/Users/fae")
        XCTAssertEqual(url.path, "/custom/cache")
    }

    func testHubCacheRootHonorsHFHomeOverride() {
        let url = KokoroFallbackCacheSeeder.hubCacheRoot(
            env: ["HF_HOME": "/custom/home"], homeDirectory: "/Users/fae")
        XCTAssertEqual(url.path, "/custom/home/hub")
    }

    func testHubCacheRootDefaultUnderHome() {
        let url = KokoroFallbackCacheSeeder.hubCacheRoot(
            env: [:], homeDirectory: "/Users/fae")
        XCTAssertEqual(url.path, "/Users/fae/.cache/huggingface/hub")
    }

    func testHubCacheRootHFHubCacheBeatsHFHome() {
        // HF_HUB_CACHE is the higher-priority override.
        let url = KokoroFallbackCacheSeeder.hubCacheRoot(
            env: ["HF_HUB_CACHE": "/a", "HF_HOME": "/b"], homeDirectory: "/Users/fae")
        XCTAssertEqual(url.path, "/a")
    }

    func testRepoSubdirIsTheMlxLayoutResolveChecksFirst() {
        // Pins the dest subdir name mlx-audio-swift's resolveOrDownloadModel
        // computes (ModelUtils.swift:73-76). A drift here would silently break
        // the "no download" guarantee.
        XCTAssertEqual(
            KokoroFallbackCacheSeeder.repoSubdir,
            "mlx-audio/prince-canuma_Kokoro-82M")
    }

    // MARK: - seed(from:to:) copy + idempotency

    private func makeTempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSeedCopiesBothFilesWhenAbsent() throws {
        let src = try makeTempDir("src")
        let dest = try makeTempDir("dest")
        try Data("[{\"k\":\"v\"}]".utf8).write(to: src.appendingPathComponent("config.json"))
        try Data([0x42, 0x43, 0x44]).write(to: src.appendingPathComponent("kokoro-v1_0.safetensors"))
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dest)
        }

        KokoroFallbackCacheSeeder.seed(from: src, to: dest)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dest.appendingPathComponent("config.json").path),
            "config.json should be copied")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dest.appendingPathComponent("kokoro-v1_0.safetensors").path),
            "weights should be copied")
    }

    func testSeedIsIdempotentAndDoesNotOverwritePopulatedDest() throws {
        let src = try makeTempDir("src")
        let dest = try makeTempDir("dest")
        try Data("new".utf8).write(to: src.appendingPathComponent("config.json"))
        try Data("new-weights".utf8).write(to: src.appendingPathComponent("kokoro-v1_0.safetensors"))
        // Dest already populated with different bytes.
        try Data("existing".utf8).write(to: dest.appendingPathComponent("config.json"))
        try Data("existing-weights".utf8).write(to: dest.appendingPathComponent("kokoro-v1_0.safetensors"))
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dest)
        }

        KokoroFallbackCacheSeeder.seed(from: src, to: dest)

        // Idempotent → existing dest bytes untouched (no overwrite).
        let cfg = try Data(contentsOf: dest.appendingPathComponent("config.json"))
        XCTAssertEqual(String(data: cfg, encoding: .utf8), "existing")
    }

    func testSeedGracefullyHandlesMissingSource() throws {
        // A non-existent source must not crash; the dest dir may be created but
        // the files are absent (the download path remains the fallback).
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let dest = try makeTempDir("dest")
        defer { try? FileManager.default.removeItem(at: dest) }

        KokoroFallbackCacheSeeder.seed(from: missing, to: dest)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dest.appendingPathComponent("config.json").path),
            "missing source must not produce a config.json")
    }
}
