import Foundation

/// Rolling git-based backup vault for all Fae user data.
///
/// Vault location: `~/.fae-vault/` — survives app deletion since it's
/// outside `~/Library/Application Support/fae/`.
///
/// Uses system git (`/usr/bin/git`) via Process for all operations.
actor GitVaultManager {

    /// Result of a vault operation.
    enum VaultOperationResult: Sendable {
        case success(commitHash: String)
        case noChanges
        case failure(String)
    }

    /// A snapshot in the vault history.
    struct VaultSnapshot: Sendable {
        let commitHash: String
        let date: Date
        let message: String
    }

    /// Current vault state.
    enum VaultState: Sendable {
        case uninitialized
        case ready
        case backingUp
        case restoring
        case error(String)
    }

    private(set) var state: VaultState = .uninitialized

    private var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private let vaultURL: URL
    private let dataURL: URL
    private let sourceDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.vaultURL = home.appendingPathComponent(".fae-vault")
        self.dataURL = vaultURL.appendingPathComponent("data")

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? home.appendingPathComponent("Library/Application Support")
        self.sourceDir = appSupport.appendingPathComponent("fae")
    }

    // MARK: - Lifecycle

    /// Ensure the vault exists and is initialized.
    func ensureVault() throws {
        let fm = FileManager.default

        try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dataURL.appendingPathComponent("skills"),
            withIntermediateDirectories: true
        )

        if !fm.fileExists(atPath: vaultURL.appendingPathComponent(".git").path) {
            try runGit("init")

            let gitattributes = "*.db binary\n*.sqlite binary\n"
            try gitattributes.write(
                to: vaultURL.appendingPathComponent(".gitattributes"),
                atomically: true, encoding: .utf8
            )

            let meta: [String: Any] = [
                "vault_version": 1,
                "created": ISO8601DateFormatter().string(from: Date()),
                "source_path": sourceDir.path,
            ]
            if let jsonData = try? JSONSerialization.data(
                withJSONObject: meta, options: .prettyPrinted
            ) {
                try jsonData.write(to: vaultURL.appendingPathComponent(".vault-meta.json"))
            }

            try runGit("config", "user.name", "Fae Vault")
            try runGit("config", "user.email", "vault@fae.local")
            try runGit("config", "gc.reflogExpire", "90.days")

            try runGit("add", "-A")
            try runGit("commit", "-m", "vault: initialized", "--allow-empty")

            state = .ready
            NSLog("GitVaultManager: vault initialized at %@", vaultURL.path)
        } else {
            state = .ready
            NSLog("GitVaultManager: vault opened at %@", vaultURL.path)
        }
    }

    // MARK: - Backup

    /// Full backup of all Fae data files.
    func backup(reason: String) async -> VaultOperationResult {
        guard isReady else {
            return .failure("Vault not ready: \(state)")
        }
        state = .backingUp
        defer { state = .ready }

        do {
            try copySourceFiles(configOnly: false)
            try runGit("add", "-A")

            let status = try runGitOutput("status", "--porcelain")
            guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .noChanges
            }

            try runGit("commit", "-m", "vault: \(reason)")
            setDataPermissions(readOnly: true)

            let hash = try runGitOutput("rev-parse", "--short", "HEAD")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            NSLog("GitVaultManager: backup complete (%@) — %@", hash, reason)
            return .success(commitHash: hash)
        } catch {
            NSLog("GitVaultManager: backup failed: %@", error.localizedDescription)
            return .failure(error.localizedDescription)
        }
    }

    /// Fast backup of config files only (no SQLite databases).
    func backupConfigOnly(changeKey: String) async -> VaultOperationResult {
        guard isReady else {
            return .failure("Vault not ready: \(state)")
        }
        state = .backingUp
        defer { state = .ready }

        do {
            try copySourceFiles(configOnly: true)
            try runGit("add", "-A")

            let status = try runGitOutput("status", "--porcelain")
            guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .noChanges
            }

            try runGit("commit", "-m", "config: \(changeKey)")

            let hash = try runGitOutput("rev-parse", "--short", "HEAD")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(commitHash: hash)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - History

    /// List recent vault snapshots.
    func listSnapshots(limit: Int = 20) throws -> [VaultSnapshot] {
        let output = try runGitOutput("log", "--format=%H|%aI|%s", "-\(limit)")
        let formatter = ISO8601DateFormatter()

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2)
            guard parts.count >= 3 else { return nil }
            let hash = String(parts[0])
            let date = formatter.date(from: String(parts[1])) ?? Date()
            let message = String(parts[2])
            return VaultSnapshot(commitHash: hash, date: date, message: message)
        }
    }

    /// Total number of commits in the vault.
    func commitCount() -> Int {
        guard let output = try? runGitOutput("rev-list", "--count", "HEAD") else { return 0 }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Restore

    /// Restore files from a specific commit (or HEAD if nil).
    func restore(commitHash: String? = nil) async throws {
        guard isReady else {
            throw VaultError.notReady
        }
        state = .restoring
        defer { state = .ready }

        let ref = commitHash ?? "HEAD"
        setDataPermissions(readOnly: false)

        try runGit("checkout", ref, "--", "data/")

        let fm = FileManager.default
        let configFiles = ["config.toml", "directive.md", "SOUL.md", "speakers.json"]

        for file in configFiles {
            let src = dataURL.appendingPathComponent(file)
            let dst = sourceDir.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }

        for dbFile in ["fae.db", "scheduler.db"] {
            let src = dataURL.appendingPathComponent(dbFile)
            let dst = sourceDir.appendingPathComponent(dbFile)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: URL(fileURLWithPath: dst.path + "-wal"))
                try? fm.removeItem(at: URL(fileURLWithPath: dst.path + "-shm"))
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }

        let srcSkills = dataURL.appendingPathComponent("skills")
        let dstSkills = sourceDir.appendingPathComponent("skills")
        if fm.fileExists(atPath: srcSkills.path) {
            try? fm.removeItem(at: dstSkills)
            try fm.copyItem(at: srcSkills, to: dstSkills)
        }

        try runGit("checkout", "HEAD", "--", "data/")
        setDataPermissions(readOnly: true)

        NSLog("GitVaultManager: restored from %@", ref)
    }

    // MARK: - Private Helpers

    private func copySourceFiles(configOnly: Bool) throws {
        let fm = FileManager.default
        setDataPermissions(readOnly: false)

        let configFiles = ["config.toml", "directive.md", "SOUL.md", "speakers.json"]
        for file in configFiles {
            let src = sourceDir.appendingPathComponent(file)
            let dst = dataURL.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }

        if !configOnly {
            for dbFile in ["fae.db", "scheduler.db"] {
                let src = sourceDir.appendingPathComponent(dbFile)
                let dst = dataURL.appendingPathComponent(dbFile)
                if fm.fileExists(atPath: src.path) {
                    try? fm.removeItem(at: dst)
                    if !vacuumInto(source: src.path, destination: dst.path) {
                        try fm.copyItem(at: src, to: dst)
                    }
                }
            }

            let srcSkills = sourceDir.appendingPathComponent("skills")
            let dstSkills = dataURL.appendingPathComponent("skills")
            if fm.fileExists(atPath: srcSkills.path) {
                try? fm.removeItem(at: dstSkills)
                try fm.copyItem(at: srcSkills, to: dstSkills)
            }
        }
    }

    private func vacuumInto(source: String, destination: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [source, "VACUUM INTO '\(destination)';"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func setDataPermissions(readOnly: Bool) {
        let mode: Int16 = readOnly ? 0o555 : 0o755
        try? FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: dataURL.path
        )
    }

    @discardableResult
    private func runGit(_ args: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", vaultURL.path] + args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw VaultError.gitFailed(args.joined(separator: " "), process.terminationStatus)
        }
        return process.terminationStatus
    }

    private func runGitOutput(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", vaultURL.path] + args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw VaultError.gitFailed(args.joined(separator: " "), process.terminationStatus)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum VaultError: LocalizedError {
        case notReady
        case gitFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Vault is not ready"
            case .gitFailed(let cmd, let status):
                return "git \(cmd) failed with exit code \(status)"
            }
        }
    }
}
