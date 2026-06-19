import XCTest
@testable import Fae

/// Stage 1 (P3/C3): TrainingBridge must produce a **verified** GGUF the daemon
/// can load, and fail loud when the conversion produces no usable artifact.
///
/// These drive the real `convertToGGUF` path (frame build → script exec → on-disk
/// verification) through a fake `uv` shim so no real Python/uv is required. The
/// shim emulates `uv run --script <convert_to_gguf.py> <jsonParams>` by reading
/// the JSON, optionally creating the requested `outfile`, and echoing the script
/// contract `{status, gguf_path, size_bytes}` to stdout — exactly what the real
/// script emits. The point is to verify the BRIDGE's contract, not Python.
final class TrainingBridgeGGUFTests: XCTestCase {

    /// Make a temp working directory unique to one test.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-gguf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write an executable fake `uv` shim that parses the JSON params (argv after
    /// `run --script <script>`), and behaves per `mode`:
    /// - "ok": create the outfile with `bytes` bytes, print an ok JSON envelope.
    /// - "ok_missing": print an ok JSON but DO NOT create the outfile (tests the
    ///   bridge's independent on-disk verification — a lying script must still fail).
    /// - "error": print a `{status:"error", error:"..."}` JSON (exit 0).
    ///
    /// `JSONSerialization` escapes forward slashes (`/` → `\/`), as the real
    /// `json.loads` un-escapes; the shim un-escapes them with `sed 's|\\/|/|g'`
    /// before using the path (a pure-shell stand-in for `json.loads`).
    private func writeFakeUV(in dir: URL, mode: String, bytes: Int = 2048) throws -> String {
        let script: String
        switch mode {
        case "ok":
            script = """
            #!/bin/bash
            # args: run --script <script.py> <jsonParams>
            json="${@: -1}"
            outfile=$(printf '%s' "$json" | sed -n 's/.*"outfile" *: *"\\([^"]*\\)".*/\\1/p' | sed 's|\\\\/|/|g')
            mkdir -p "$(dirname "$outfile")"
            head -c \(bytes) /dev/zero > "$outfile"
            size=$(wc -c < "$outfile" | tr -d ' ')
            printf '{"status":"ok","gguf_path":"%s","size_bytes":%s,"outtype":"f16"}\\n' "$outfile" "$size"
            """
        case "ok_missing":
            script = """
            #!/bin/bash
            json="${@: -1}"
            outfile=$(printf '%s' "$json" | sed -n 's/.*"outfile" *: *"\\([^"]*\\)".*/\\1/p' | sed 's|\\\\/|/|g')
            printf '{"status":"ok","gguf_path":"%s","size_bytes":4096,"outtype":"f16"}\\n' "$outfile"
            """
        case "error":
            script = """
            #!/bin/bash
            printf '{"status":"error","error":"convert_lora_to_gguf failed","stderr":"boom"}\\n'
            """
        default:
            script = "#!/bin/bash\nexit 0\n"
        }
        let uvURL = dir.appendingPathComponent("uv")
        try script.write(to: uvURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: uvURL.path)
        return uvURL.path
    }

    /// `convert_to_gguf.py` must exist for `runScript`'s existence check — its
    /// contents are irrelevant because the fake `uv` ignores the file body.
    private func touchConvertScript(in dir: URL) throws {
        try "# fake".write(
            to: dir.appendingPathComponent("convert_to_gguf.py"),
            atomically: true, encoding: .utf8)
    }

    // MARK: - Success path

    func testConvertToGGUFReturnsVerifiedPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touchConvertScript(in: dir)
        let uv = try writeFakeUV(in: dir, mode: "ok", bytes: 4096)

        let bridge = TrainingBridge(
            uvPath: uv,
            orchestratorScriptsDir: dir,
            dataBridgeScriptsDir: dir)

        let outfile = dir.appendingPathComponent("adapter/personal.gguf").path
        let result = try await bridge.convertToGGUF(
            adapterPath: dir.appendingPathComponent("adapter").path,
            baseModel: "google/gemma-4-E4B-it",
            outfile: outfile)

        XCTAssertEqual(result.ggufPath, outfile)
        XCTAssertEqual(result.sizeBytes, 4096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.ggufPath),
                      "a verified GGUF path must exist on disk")
    }

    // MARK: - Missing-GGUF failure path

    func testConvertToGGUFFailsWhenScriptLiesAboutOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touchConvertScript(in: dir)
        // Script claims success but never creates the file — the bridge must NOT
        // trust the claim and must fail loud.
        let uv = try writeFakeUV(in: dir, mode: "ok_missing")

        let bridge = TrainingBridge(
            uvPath: uv,
            orchestratorScriptsDir: dir,
            dataBridgeScriptsDir: dir)

        do {
            _ = try await bridge.convertToGGUF(
                adapterPath: dir.appendingPathComponent("adapter").path,
                baseModel: "google/gemma-4-E4B-it",
                outfile: dir.appendingPathComponent("missing.gguf").path)
            XCTFail("convertToGGUF must reject a missing/empty GGUF")
        } catch let TrainingBridgeError.ggufNotProduced(path) {
            XCTAssertTrue(path.hasSuffix("missing.gguf"))
        }
    }

    func testConvertToGGUFFailsOnEmptyArtifact() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touchConvertScript(in: dir)
        // 0-byte file: exists but empty → still not usable.
        let uv = try writeFakeUV(in: dir, mode: "ok", bytes: 0)

        let bridge = TrainingBridge(
            uvPath: uv,
            orchestratorScriptsDir: dir,
            dataBridgeScriptsDir: dir)

        do {
            _ = try await bridge.convertToGGUF(
                adapterPath: dir.appendingPathComponent("adapter").path,
                baseModel: "google/gemma-4-E4B-it",
                outfile: dir.appendingPathComponent("empty.gguf").path)
            XCTFail("convertToGGUF must reject a 0-byte GGUF")
        } catch TrainingBridgeError.ggufNotProduced {
            // expected
        }
    }

    // MARK: - Script-error propagation

    func testConvertToGGUFPropagatesScriptError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touchConvertScript(in: dir)
        let uv = try writeFakeUV(in: dir, mode: "error")

        let bridge = TrainingBridge(
            uvPath: uv,
            orchestratorScriptsDir: dir,
            dataBridgeScriptsDir: dir)

        do {
            _ = try await bridge.convertToGGUF(
                adapterPath: dir.appendingPathComponent("adapter").path,
                baseModel: "google/gemma-4-E4B-it",
                outfile: dir.appendingPathComponent("err.gguf").path)
            XCTFail("convertToGGUF must surface a script-reported error")
        } catch let TrainingBridgeError.scriptError(script, detail) {
            XCTAssertEqual(script, "convert_to_gguf.py")
            XCTAssertTrue(detail.contains("convert_lora_to_gguf failed"))
        }
    }

    // MARK: - Error descriptions for the new cases

    func testNewErrorDescriptions() {
        let e1 = TrainingBridgeError.ggufNotProduced(path: "/tmp/x.gguf")
        XCTAssertTrue(e1.localizedDescription.contains("/tmp/x.gguf"))

        let e2 = TrainingBridgeError.scriptError(script: "convert_to_gguf.py", detail: "kaboom")
        XCTAssertTrue(e2.localizedDescription.contains("convert_to_gguf.py"))
        XCTAssertTrue(e2.localizedDescription.contains("kaboom"))
    }

    // MARK: - Result struct construction

    func testPeftTrainingResultInit() {
        let r = PeftTrainingResult(
            adapterPath: "/tmp/adapter",
            ggufPath: "/tmp/adapter/personal.gguf",
            baseModel: "google/gemma-4-E4B-it",
            finalLoss: 0.0001)
        XCTAssertEqual(r.adapterPath, "/tmp/adapter")
        XCTAssertTrue(r.ggufPath.hasSuffix("personal.gguf"))
        XCTAssertEqual(r.baseModel, "google/gemma-4-E4B-it")
        XCTAssertEqual(r.finalLoss, 0.0001, accuracy: 1e-9)
    }

    func testGGUFConversionResultInit() {
        let r = GGUFConversionResult(ggufPath: "/tmp/p.gguf", sizeBytes: 123)
        XCTAssertEqual(r.ggufPath, "/tmp/p.gguf")
        XCTAssertEqual(r.sizeBytes, 123)
    }
}
