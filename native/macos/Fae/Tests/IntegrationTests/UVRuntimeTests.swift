import XCTest
@testable import Fae

/// Tests for the UVRuntime Python integration layer.
final class UVRuntimeTests: XCTestCase {
    
    /// Verify that uv can be found on the system.
    /// This test will skip if uv is not installed.
    func testUVIsAvailable() async throws {
        let uv = UVRuntime.shared
        let available = await uv.isAvailable()
        
        // If uv is available, we can test further. Otherwise, skip.
        if !available {
            throw XCTSkip("uv is not installed on this system")
        }
        
        let path = await uv.path()
        XCTAssertNotNil(path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path!))
    }
    
    /// Verify that we can get uv version info.
    func testUVInfo() async throws {
        let uv = UVRuntime.shared
        guard await uv.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        
        let info = await uv.info()
        XCTAssertNotNil(info)
        XCTAssertFalse(info!.version.isEmpty)
        XCTAssertFalse(info!.path.isEmpty)
    }
    
    /// Verify that we can create a process for a simple Python script.
    func testCreateScriptProcess() async throws {
        let uv = UVRuntime.shared
        guard await uv.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        
        // Create a temporary script with PEP 723 metadata
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("test_script_\(UUID().uuidString).py")
        
        let scriptContent = """
        #!/usr/bin/env python3
        # /// script
        # requires-python = ">=3.11"
        # dependencies = []
        # ///
        print("Hello from Python!")
        """
        
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }
        
        // Create the process
        let process = try await uv.createScriptProcess(scriptPath: scriptURL)
        XCTAssertNotNil(process.executableURL)
        XCTAssertTrue(process.arguments?.contains("--script") ?? false)
    }
    
    /// Verify that runScript executes and returns output.
    func testRunScript() async throws {
        let uv = UVRuntime.shared
        guard await uv.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        
        // Create a temporary script
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("test_run_\(UUID().uuidString).py")
        
        let scriptContent = """
        #!/usr/bin/env python3
        # /// script
        # requires-python = ">=3.11"
        # dependencies = []
        # ///
        import sys
        print("stdout message")
        print("stderr message", file=sys.stderr)
        """
        
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }
        
        // Run the script
        let (stdout, stderr) = try await uv.runScript(scriptPath: scriptURL, timeout: 30)
        XCTAssertTrue(stdout.contains("stdout message"))
        XCTAssertTrue(stderr.contains("stderr message"))
    }
    
    /// Verify that runScript times out appropriately.
    func testRunScriptTimeout() async throws {
        let uv = UVRuntime.shared
        guard await uv.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        
        // Create a script that sleeps
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("test_timeout_\(UUID().uuidString).py")
        
        let scriptContent = """
        #!/usr/bin/env python3
        # /// script
        # requires-python = ">=3.11"
        # dependencies = []
        # ///
        import time
        time.sleep(10)
        print("Should not reach here")
        """
        
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }
        
        // Run with a short timeout
        do {
            _ = try await uv.runScript(scriptPath: scriptURL, timeout: 1)
            XCTFail("Expected script to be terminated due to timeout")
        } catch let error as UVRuntime.UVError {
            // The script should have been terminated
            if case .executionFailed(let msg) = error {
                // Expected - script was killed or returned non-zero
                XCTAssertTrue(msg.contains("Exit code") || msg.contains("terminated"))
            }
        } catch {
            // Some other error is also acceptable for timeout behavior
            // The script might have been killed before producing output
        }
    }
    
    /// Verify that creating a process for a non-existent script throws.
    func testScriptNotFound() async throws {
        let uv = UVRuntime.shared
        guard await uv.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        
        let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent_script_\(UUID().uuidString).py")
        
        do {
            _ = try await uv.createScriptProcess(scriptPath: nonExistentURL)
            XCTFail("Expected error for non-existent script")
        } catch let error as UVRuntime.UVError {
            if case .scriptNotFound = error {
                // Expected
            } else {
                XCTFail("Expected scriptNotFound error, got: \(error)")
            }
        }
    }
}
