import XCTest

/// Local-dev convenience: skip heavy EndToEnd tests when FAE_SKIP_HEAVY_TESTS=1.
/// CI does NOT set this env var — the full suite runs in CI for coverage.
/// Every skip prints a visible XCTSkip reason; never a silent green.
enum HeavyTestSkip {
    static func skipIfRequested() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["FAE_SKIP_HEAVY_TESTS"] == "1",
            "Skipped via FAE_SKIP_HEAVY_TESTS=1 (local-dev convenience; CI runs the full suite)"
        )
    }
}
