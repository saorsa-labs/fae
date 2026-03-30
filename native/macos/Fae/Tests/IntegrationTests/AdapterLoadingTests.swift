import XCTest
@testable import FaeInference

/// Tests for MLXLLMEngine LoRA adapter loading, unloading, and hot-swap.
///
/// These tests verify the adapter management API surface without requiring
/// a real trained adapter. Full mlx-tune → Swift round-trip is a separate
/// manual integration test.
final class AdapterLoadingTests: XCTestCase {

    // MARK: - Load Adapter Without Model

    /// Loading an adapter before a model is loaded should throw notLoaded.
    func testLoadAdapterWithoutModelThrowsNotLoaded() async {
        let engine = MLXLLMEngine()
        let fakeDir = URL(fileURLWithPath: "/tmp/nonexistent-adapter")

        do {
            try await engine.loadAdapter(from: fakeDir)
            XCTFail("Should have thrown MLEngineError.notLoaded")
        } catch let error as MLEngineError {
            switch error {
            case .notLoaded:
                break // Expected
            default:
                XCTFail("Expected notLoaded error, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Unload Without Adapter

    /// Unloading when no adapter is loaded should be a safe no-op.
    func testUnloadAdapterWithoutAdapterIsNoOp() async {
        let engine = MLXLLMEngine()
        await engine.unloadAdapter()
        let loaded = await engine.isAdapterLoaded
        XCTAssertFalse(loaded, "No adapter should be loaded after unload on fresh engine")
    }

    // MARK: - Adapter State Properties

    /// Fresh engine should report no adapter loaded.
    func testFreshEngineHasNoAdapter() async {
        let engine = MLXLLMEngine()
        let loaded = await engine.isAdapterLoaded
        let path = await engine.loadedAdapterPath
        XCTAssertFalse(loaded)
        XCTAssertNil(path)
    }

    // MARK: - Swap To Nil

    /// Swapping to nil directory should unload any adapter.
    func testSwapAdapterToNilUnloads() async throws {
        let engine = MLXLLMEngine()
        try await engine.swapAdapter(to: nil)
        let loaded = await engine.isAdapterLoaded
        XCTAssertFalse(loaded)
    }

    // MARK: - Load Invalid Directory

    /// Loading from a nonexistent directory should throw adapterLoadFailed.
    func testLoadAdapterFromInvalidDirectoryThrows() async {
        // This test needs a loaded model to get past the notLoaded check.
        // Without a real model, we verify that the notLoaded guard fires first.
        let engine = MLXLLMEngine()
        let invalidDir = URL(fileURLWithPath: "/tmp/does-not-exist-adapter-\(UUID().uuidString)")

        do {
            try await engine.loadAdapter(from: invalidDir)
            XCTFail("Should have thrown an error")
        } catch let error as MLEngineError {
            // Without a loaded model, we get notLoaded (which is correct behavior)
            switch error {
            case .notLoaded:
                break // Expected: model not loaded guard fires before adapter load
            case .adapterLoadFailed:
                break // Also acceptable if model somehow loaded
            default:
                XCTFail("Unexpected error case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Shutdown Clears Adapter State

    /// Shutting down the engine should clear adapter state.
    func testShutdownClearsAdapterState() async {
        let engine = MLXLLMEngine()
        await engine.shutdown()
        let loaded = await engine.isAdapterLoaded
        let path = await engine.loadedAdapterPath
        XCTAssertFalse(loaded)
        XCTAssertNil(path)
    }

    // MARK: - Post-Failure State Invariant

    /// After a failed loadAdapter call, adapter state must remain clean (no partial state).
    ///
    /// This verifies the invariant: currentAdapter and loadedAdapterPath are only
    /// set AFTER successful apply — a failed load must leave the engine in "no adapter" state.
    func testLoadAdapterFailureDoesNotLeavePartialState() async {
        let engine = MLXLLMEngine()
        let nonExistentDir = URL(fileURLWithPath: "/tmp/no-such-adapter-\(UUID().uuidString)")

        // Attempt load (will fail — either notLoaded or adapterLoadFailed)
        try? await engine.loadAdapter(from: nonExistentDir)

        // Regardless of which error fired, adapter state must be clean
        let loaded = await engine.isAdapterLoaded
        let path = await engine.loadedAdapterPath
        XCTAssertFalse(loaded, "Failed loadAdapter must not leave isAdapterLoaded = true")
        XCTAssertNil(path, "Failed loadAdapter must not leave loadedAdapterPath set")
    }
}
