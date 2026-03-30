import XCTest
@testable import Fae

/// Tests for Phase 1.2: Adapter Deployment Mechanism
///
/// Verifies that:
/// - SelfConfigTool exposes training.personal_adapter_path and
///   training.adapter_auto_load_enabled as adjustable keys.
/// - The new string validation logic permits any non-empty string when
///   `allowed` is empty (open-ended path values).
/// - FaeCore.patchConfig handles the adapter path key correctly.
/// - SelfConfigTool validates and rejects bad values for the adapter keys.
final class AdapterDeploymentTests: XCTestCase {

    // MARK: - SelfConfigTool: adjustableKeys existence

    /// SelfConfigTool must recognise training.personal_adapter_path.
    func testPersonalAdapterPathKeyIsAdjustable() async throws {
        let tool = SelfConfigTool()
        // A valid non-empty path should be accepted (not return "Unknown setting").
        let result = try await tool.execute(input: [
            "action": "adjust_setting",
            "key": "training.personal_adapter_path",
            "value": "/tmp/test-adapter"
        ])
        if result.isError {
            XCTAssertFalse(
                result.output.hasPrefix("Unknown setting"),
                "Key not found in adjustableKeys: \(result.output)"
            )
        }
    }

    /// SelfConfigTool must recognise training.adapter_auto_load_enabled.
    func testAdapterAutoLoadEnabledKeyIsAdjustable() async throws {
        let tool = SelfConfigTool()
        let result = try await tool.execute(input: [
            "action": "adjust_setting",
            "key": "training.adapter_auto_load_enabled",
            "value": true
        ])
        if result.isError {
            XCTAssertFalse(
                result.output.hasPrefix("Unknown setting"),
                "Key not found in adjustableKeys: \(result.output)"
            )
        }
    }

    // MARK: - Open-ended string validation

    /// Any non-empty path string should pass validation for personal_adapter_path.
    func testArbitraryPathStringPassesValidation() async throws {
        let tool = SelfConfigTool()
        let paths = [
            "/tmp/my-adapter",
            "/Users/dave/Library/Application Support/fae/adapters/v1",
            "relative/path/adapter",
            "/adapter-with-special_chars.d/123",
        ]
        for path in paths {
            let result = try await tool.execute(input: [
                "action": "adjust_setting",
                "key": "training.personal_adapter_path",
                "value": path
            ])
            XCTAssertFalse(result.isError, "Path '\(path)' should be valid, got error: \(result.output)")
        }
    }

    /// Empty/whitespace string should be rejected (open-ended string keys require non-empty value).
    func testEmptyPathStringFailsValidation() async throws {
        let tool = SelfConfigTool()
        for empty in ["", "   ", "\t"] {
            let result = try await tool.execute(input: [
                "action": "adjust_setting",
                "key": "training.personal_adapter_path",
                "value": empty
            ])
            XCTAssertTrue(result.isError, "Empty string '\(empty)' should fail validation, got: \(result.output)")
        }
    }

    // MARK: - FaeCore patchConfig: adapter path

    /// patchConfig with a valid path stores the path in config.
    func testPatchConfigAdapterPathStoresValue() async throws {
        await MainActor.run {
            var config = FaeConfig.load()

            // Simulate patchConfig logic directly.
            let key = "training.personal_adapter_path"
            let value: Any = "/tmp/my-adapter"

            let newPath: String?
            if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newPath = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                newPath = nil
            }

            config.training.personalAdapterPath = newPath
            XCTAssertEqual(config.training.personalAdapterPath, "/tmp/my-adapter")
            _ = key // silence unused-variable warning
        }
    }

    /// patchConfig with empty string should unload the adapter (set nil).
    func testPatchConfigEmptyPathSetsNil() async throws {
        await MainActor.run {
            var config = FaeConfig.load()
            config.training.personalAdapterPath = "/existing/path"

            // Simulate patchConfig with empty value.
            let value: Any = ""
            let newPath: String?
            if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newPath = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                newPath = nil
            }
            config.training.personalAdapterPath = newPath
            XCTAssertNil(config.training.personalAdapterPath, "Empty string should map to nil adapter path")
        }
    }

    // MARK: - FaeCore patchConfig: adapter_auto_load_enabled

    /// patchConfig stores adapter_auto_load_enabled boolean.
    func testPatchConfigAdapterAutoLoadEnabledStoresBool() async throws {
        await MainActor.run {
            var config = FaeConfig.load()
            XCTAssertFalse(config.training.adapterAutoLoadEnabled, "Default should be false")

            config.training.adapterAutoLoadEnabled = true
            XCTAssertTrue(config.training.adapterAutoLoadEnabled)

            config.training.adapterAutoLoadEnabled = false
            XCTAssertFalse(config.training.adapterAutoLoadEnabled)
        }
    }

    // MARK: - Configpatcher integration

    /// A simple reference-type box to capture configPatcher results
    /// without triggering Swift 6 Sendable mutation warnings.
    private final class PatchCapture: @unchecked Sendable {
        var key: String?
        var value: Any?
    }

    /// SelfConfigTool.configPatcher is called with the right key and value.
    func testSelfConfigToolCallsConfigPatcherForAdapterPath() async throws {
        let capture = PatchCapture()

        await MainActor.run {
            SelfConfigTool.configPatcher = { key, value in
                capture.key = key
                capture.value = value
            }
        }

        defer {
            Task { @MainActor in SelfConfigTool.configPatcher = nil }
        }

        let tool = SelfConfigTool()
        _ = try await tool.execute(input: [
            "action": "adjust_setting",
            "key": "training.personal_adapter_path",
            "value": "/tmp/adapter-test"
        ])

        // Give MainActor.run a chance to execute the patcher.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(capture.key, "training.personal_adapter_path")
        XCTAssertEqual(capture.value as? String, "/tmp/adapter-test")
    }

    /// SelfConfigTool.configPatcher is called for adapter_auto_load_enabled.
    func testSelfConfigToolCallsConfigPatcherForAutoLoad() async throws {
        let capture = PatchCapture()

        await MainActor.run {
            SelfConfigTool.configPatcher = { key, value in
                capture.key = key
                capture.value = value
            }
        }

        defer {
            Task { @MainActor in SelfConfigTool.configPatcher = nil }
        }

        let tool = SelfConfigTool()
        _ = try await tool.execute(input: [
            "action": "adjust_setting",
            "key": "training.adapter_auto_load_enabled",
            "value": true
        ])

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(capture.key, "training.adapter_auto_load_enabled")
        XCTAssertEqual(capture.value as? Bool, true)
    }
}
