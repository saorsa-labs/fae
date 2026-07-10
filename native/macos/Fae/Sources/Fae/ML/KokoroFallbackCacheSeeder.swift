import Foundation

/// Seeds the mlx-audio-swift Hugging Face cache for `prince-canuma/Kokoro-82M`
/// from the bundled Kokoro assets (task #35) so `FaeTTSAdapter.load` →
/// `TTS.loadModel` → `ModelUtils.resolveOrDownloadModel` resolves LOCALLY — no
/// first-use download on the live reply path when the daemon TTS lane fails.
///
/// `resolveOrDownloadModel` (vendored `mlx-audio-swift`, file
/// `Sources/MLXAudioCore/ModelUtils.swift:73-104`) checks
/// `<hf-cache>/mlx-audio/prince-canuma_Kokoro-82M/` FIRST; if a non-zero
/// `.safetensors` + a valid `config.json` are present it returns immediately
/// (line 94) and never reaches `downloadSnapshot` (line 119). This seeder
/// materialises exactly those two files from the app bundle
/// (`Contents/Resources/Kokoro/`).
///
/// Idempotent (skips when both dest files exist) and APFS-clone-friendly
/// (`FileManager.copyItem` reflinks on the same volume → ~ms, ~0 extra disk).
/// A failure (disk full / permissions / missing bundle) is non-fatal: the dest
/// stays incomplete and `resolveOrDownloadModel` falls through to its existing
/// `downloadSnapshot` — the never-silent guarantee degrades to today's
/// behaviour (graceful download, not silence).
///
/// - Note (sandbox): `hubCacheRoot` resolves to `~/.cache/huggingface/hub`,
///   correct for NON-sandboxed macOS (Fae reads contacts/mail/calendar, so it is
///   not sandboxed). A hypothetical sandboxed build would need parity with
///   `~/Library/Caches/huggingface/hub` (`APP_SANDBOX_CONTAINER_ID` set) —
///   benign today; flagged here so a future sandbox attempt doesn't silently
///   re-enable the download.
/// - Note (VENDOR BUMP): when bumping `mlx-audio-swift`, re-verify that
///   `repoSubdir` + `resolveOrDownloadModel`'s cache-layout (`ModelUtils.swift`
///   73-104) still agree. Drift fails gracefully (download-degrade), never
///   silence — but it would quietly undo the no-network guarantee.
///
/// `hubCacheRoot(env:homeDirectory:)` and `seed(from:to:)` are internal (not
/// private) so the `IntegrationTests` target can unit-test them in isolation
/// (`@testable import Fae`).
enum KokoroFallbackCacheSeeder {
    /// Flat layout mlx-audio-swift writes under the HF cache root
    /// (`ModelUtils.resolveOrDownloadModel`, lines 73-76). Pinned by
    /// `KokoroFallbackCacheSeederTests.testRepoSubdirIsTheMlxLayoutResolveChecksFirst`.
    static let repoSubdir = "mlx-audio/prince-canuma_Kokoro-82M"
    static let weightsFile = "kokoro-v1_0.safetensors"
    static let configFile = "config.json"

    /// HF hub cache root, replicating `HubCache.default.cacheDirectory`
    /// (swift-huggingface `CacheLocationProvider.resolveFromEnvironment`):
    /// `HF_HUB_CACHE` → `HF_HOME/hub` → `~/.cache/huggingface/hub`
    /// (non-sandboxed macOS). Replicated rather than `import HuggingFace` to
    /// avoid a Package.swift dependency change; the logic is stable (mirrors
    /// Python `huggingface_hub`). Parametrised for unit testing.
    static func hubCacheRoot(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        if let raw = env["HF_HUB_CACHE"] {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let home = env["HF_HOME"] {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    /// Entry point: seed the cache from the app bundle if present. No-op when
    /// the bundle is absent (back-compat: download path unchanged).
    static func seedIfNeeded() {
        guard let bundledPath = DaemonLLMEngine.bundledKokoroModelDirectory() else { return }
        let dest = hubCacheRoot().appendingPathComponent(repoSubdir, isDirectory: true)
        seed(from: URL(fileURLWithPath: bundledPath, isDirectory: true), to: dest)
    }

    /// Copy `config.json` + `kokoro-v1_0.safetensors` from `bundled` into `dest`
    /// if not already present. Idempotent; a failure logs and leaves `dest`
    /// incomplete so `resolveOrDownloadModel` falls through to its download path.
    static func seed(from bundled: URL, to dest: URL) {
        let destWeights = dest.appendingPathComponent(weightsFile)
        let destConfig = dest.appendingPathComponent(configFile)

        // Idempotent: both files already present → nothing to do.
        if FileManager.default.fileExists(atPath: destWeights.path),
           FileManager.default.fileExists(atPath: destConfig.path) {
            return
        }

        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            // copyItem APFS-clones on the same volume (bundle + ~ share the data
            // volume on a typical macOS install) → ~ms, ~0 extra disk.
            if !FileManager.default.fileExists(atPath: destConfig.path) {
                try FileManager.default.copyItem(
                    at: bundled.appendingPathComponent(configFile), to: destConfig)
            }
            if !FileManager.default.fileExists(atPath: destWeights.path) {
                try FileManager.default.copyItem(
                    at: bundled.appendingPathComponent(weightsFile), to: destWeights)
            }
            NSLog(
                "KokoroFallbackCacheSeeder: seeded mlx-audio Kokoro cache from bundle → %@ (no first-use download)",
                dest.path)
        } catch {
            // Graceful degrade: dest incomplete → resolveOrDownloadModel falls
            // through to downloadSnapshot (never-silent preserved).
            NSLog(
                "KokoroFallbackCacheSeeder: seed FAILED (%@) — will use the download fallback",
                error.localizedDescription)
        }
    }
}
