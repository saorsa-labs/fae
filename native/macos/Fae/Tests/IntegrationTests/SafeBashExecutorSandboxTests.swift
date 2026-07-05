import XCTest
@testable import Fae

/// Proves the C2 fix: bash runs under a macOS seatbelt sandbox that DENIES
/// reading the protected credential/identity files, closing the hole where a
/// prompt-injected local model exfiltrated secrets via substring-evading shell
/// (`cd ~ && cat .secrets`, `cat ~/.sec*`, `tar czf /tmp/x.tgz ~`, …). The
/// generated-profile tests are pure; the enforcement tests exercise the real
/// wrapped executor against hermetic temp files so no real secret is touched.
final class SafeBashExecutorSandboxTests: XCTestCase {

    // MARK: - Generated profile denies every protected path

    func testProfileDeniesEveryProtectedReadPath() {
        let home = "/Users/testhome"
        let profile = SafeBashExecutor.seatbeltProfile(home: home)

        // Fail-closed shape: default-allow so legitimate bash works, then an
        // explicit read denial block.
        XCTAssertTrue(profile.contains("(allow default)"))
        XCTAssertTrue(profile.contains("(deny file-read*"))

        for path in SafeBashExecutor.protectedReadPaths(home: home) {
            XCTAssertTrue(
                profile.contains("(subpath \"\(path)\")"),
                "seatbelt profile must deny file-read* of protected path \(path)"
            )
        }
    }

    func testProtectedPathsCoverSecretsCredentialsAndIdentity() {
        let home = "/Users/testhome"
        let paths = Set(SafeBashExecutor.protectedReadPaths(home: home))
        // Secrets (the direct C2 target), credential dirs (the B-HOLD-2
        // hardening), and Fae identity files must all be present.
        for expected in [
            "\(home)/.secrets",
            "\(home)/.env",
            "\(home)/.saorsa-keys",
            "\(home)/.ssh",
            "\(home)/.aws",
            "\(home)/.gnupg",
            "\(home)/.netrc",
            "\(home)/.fae-vault",
            "\(home)/Library/Application Support/fae/speakers.json",
            "\(home)/Library/Application Support/fae/directive.md",
        ] {
            XCTAssertTrue(paths.contains(expected), "missing protected path \(expected)")
        }
    }

    func testProfileQuotesEscapeSpecialCharacters() {
        let profile = SafeBashExecutor.seatbeltProfile(
            home: #"/Users/od"d"#, extraDenyReadPaths: [])
        // A double quote in the home path must be backslash-escaped inside the
        // TinyScheme literal so the profile stays well-formed (fail closed —
        // a malformed profile would make sandbox-exec refuse, not silently
        // allow).
        XCTAssertTrue(profile.contains(#"\""#))
    }

    // MARK: - Real enforcement (wrapped executor, hermetic temp files)

    func testWrappedExecutorDeniesReadingAProtectedFileButAllowsOthers() async throws {
        // sandbox-exec is a system binary on every macOS host/runner.
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: SafeBashExecutor.sandboxExecPath),
            "sandbox-exec unavailable on this host")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-sbx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a fake secret value by concatenation so it never trips secret
        // scanners and never resembles a real credential.
        let secretMarker = "TOP" + "-" + "SEEKRIT" + "-" + "42"
        let secretFile = dir.appendingPathComponent("stand-in-secret")
        let publicFile = dir.appendingPathComponent("stand-in-public")
        try secretMarker.write(to: secretFile, atomically: true, encoding: .utf8)
        try "public-ok".write(to: publicFile, atomically: true, encoding: .utf8)

        // Deny reads of the secret stand-in; the public file is NOT denied.
        let deny = [secretFile.path]

        // Denied: cat of the protected file must fail (exit != 0) and must NOT
        // leak the secret's bytes into stdout — this is the C2 read that
        // substring matching could not stop.
        let denied = try await SafeBashExecutor.execute(
            command: "cat \(secretFile.path)",
            timeoutSeconds: 15,
            extraDenyReadPaths: deny
        )
        let deniedOut = String(data: denied.stdout, encoding: .utf8) ?? ""
        XCTAssertNotEqual(denied.status, 0, "reading a protected path must fail under the sandbox")
        XCTAssertFalse(deniedOut.contains(secretMarker), "protected file contents must not leak")

        // Substring-evasion form the DamageControlPolicy needle-match misses:
        // `cd <dir> && cat <basename>`. The kernel read-deny still catches it.
        let evaded = try await SafeBashExecutor.execute(
            command: "cd \(dir.path) && cat stand-in-secret",
            timeoutSeconds: 15,
            extraDenyReadPaths: deny
        )
        let evadedOut = String(data: evaded.stdout, encoding: .utf8) ?? ""
        XCTAssertFalse(evadedOut.contains(secretMarker), "cd-relative read must not leak either")

        // Allowed: a non-protected file reads normally — legitimate bash is
        // preserved (default-allow reads).
        let allowed = try await SafeBashExecutor.execute(
            command: "cat \(publicFile.path)",
            timeoutSeconds: 15,
            extraDenyReadPaths: deny
        )
        let allowedOut = String(data: allowed.stdout, encoding: .utf8) ?? ""
        XCTAssertEqual(allowed.status, 0, "reading a non-protected file must still succeed")
        XCTAssertTrue(allowedOut.contains("public-ok"), "legitimate bash reads must work")
    }
}
