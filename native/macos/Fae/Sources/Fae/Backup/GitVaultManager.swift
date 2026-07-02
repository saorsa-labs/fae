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
        self.vaultURL = FaeDirectories.vault
        self.dataURL = vaultURL.appendingPathComponent("data")
        self.sourceDir = FaeDirectories.root
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
            let skippedDatabases = try copySourceFiles(configOnly: false)
            try runGit("add", "-A")

            let status = try runGitOutput("status", "--porcelain")
            guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .noChanges
            }

            try runGit("commit", "-m", "vault: \(reason)")
            setDataPermissions(readOnly: true)

            let hash = try runGitOutput("rev-parse", "--short", "HEAD")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // A partial snapshot (some WAL databases could not be vacuumed) must not report success.
            guard skippedDatabases.isEmpty else {
                let joined = skippedDatabases.joined(separator: ", ")
                NSLog(
                    "GitVaultManager: backup partial (%@) — %@; databases not snapshotted: %@",
                    hash, reason, joined
                )
                return .failure("partial backup \(hash): databases not snapshotted: \(joined)")
            }

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
            // Config-only backups touch no SQLite databases, so there are no vacuum skips to surface.
            _ = try copySourceFiles(configOnly: true)
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
        let configFiles = ["config.toml", "directive.md", "SOUL.md", "heartbeat.md", "speakers.json", "owner_photo.jpg", "personal_lexicon.json"]

        for file in configFiles {
            let src = dataURL.appendingPathComponent(file)
            let dst = sourceDir.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) {
                try Self.atomicallyReplace(itemAt: dst, withCopyOf: src)
            }
        }

        for dbFile in ["fae.db", "scheduler.db", "improvement.db"] {
            let src = dataURL.appendingPathComponent(dbFile)
            let dst = sourceDir.appendingPathComponent(dbFile)
            if fm.fileExists(atPath: src.path) {
                // Stage the restored db first, then swap it in atomically. Only
                // after the swap succeeds do we clear the stale WAL/SHM — a
                // failed copy must never leave a deleted-but-not-replaced db.
                try Self.atomicallyReplace(itemAt: dst, withCopyOf: src)
                try? fm.removeItem(at: URL(fileURLWithPath: dst.path + "-wal"))
                try? fm.removeItem(at: URL(fileURLWithPath: dst.path + "-shm"))
            }
        }

        let srcSkills = dataURL.appendingPathComponent("skills")
        let dstSkills = sourceDir.appendingPathComponent("skills")
        if fm.fileExists(atPath: srcSkills.path) {
            try Self.atomicallyReplace(itemAt: dstSkills, withCopyOf: srcSkills)
        }

        // Restore personal LoRA adapters.
        let srcAdapters = dataURL.appendingPathComponent("adapters")
        let dstAdapters = sourceDir.appendingPathComponent("adapters")
        if fm.fileExists(atPath: srcAdapters.path) {
            try Self.atomicallyReplace(itemAt: dstAdapters, withCopyOf: srcAdapters)
        }

        try runGit("checkout", "HEAD", "--", "data/")
        setDataPermissions(readOnly: true)

        NSLog("GitVaultManager: restored from %@", ref)
    }

    /// Copy-then-swap a restored file/directory into place without data loss.
    ///
    /// The prior implementation deleted the live file (`removeItem`) *before*
    /// copying the restored one, so a copy failure (disk full, permissions)
    /// left the user with a deleted-but-not-replaced `fae.db`. Here we copy the
    /// source into a sibling temp path first — the live file stays untouched
    /// until that copy succeeds — then atomically replace/move it into place.
    private static func atomicallyReplace(itemAt dst: URL, withCopyOf src: URL) throws {
        let fm = FileManager.default
        let staging = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).restore-\(UUID().uuidString)")

        // Stage the copy first; the live destination is not touched yet.
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: src, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        do {
            if fm.fileExists(atPath: dst.path) {
                // Atomic swap: replaceItemAt only removes the original once the
                // replacement is in place.
                _ = try fm.replaceItemAt(dst, withItemAt: staging)
            } else {
                // No existing file to swap — move the staged copy into place.
                try fm.moveItem(at: staging, to: dst)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Private Helpers

    /// Copies source files into the vault's data directory. Returns the names of any WAL SQLite
    /// databases that could not be safely snapshotted (VACUUM INTO failed) and were therefore left
    /// at their previous backed-up state — the caller must treat these as a partial-backup failure.
    private func copySourceFiles(configOnly: Bool) throws -> [String] {
        let fm = FileManager.default
        setDataPermissions(readOnly: false)
        var skippedDatabases: [String] = []

        let configFiles = ["config.toml", "directive.md", "SOUL.md", "heartbeat.md", "speakers.json", "owner_photo.jpg", "personal_lexicon.json"]
        for file in configFiles {
            let src = sourceDir.appendingPathComponent(file)
            let dst = dataURL.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }

        if !configOnly {
            for dbFile in ["fae.db", "scheduler.db", "receipts.db", "improvement.db"] {
                let src = sourceDir.appendingPathComponent(dbFile)
                let dst = dataURL.appendingPathComponent(dbFile)
                guard fm.fileExists(atPath: src.path) else { continue }
                // VACUUM INTO is the only WAL-safe snapshot; a raw copy of the main .db file while
                // writers hold the WAL yields a torn/stale backup, so we never fall back to that.
                // Vacuum into a temp file and only swap it in on success, keeping the previous good
                // snapshot in place if it fails.
                let tmp = dst.appendingPathExtension("vacuum-tmp")
                try? fm.removeItem(at: tmp)
                if vacuumInto(source: src.path, destination: tmp.path) {
                    try? fm.removeItem(at: dst)
                    try fm.moveItem(at: tmp, to: dst)
                } else {
                    try? fm.removeItem(at: tmp)
                    skippedDatabases.append(dbFile)
                    NSLog(
                        "GitVaultManager: VACUUM INTO failed for %@ — skipping (previous snapshot retained)",
                        dbFile
                    )
                }
            }

            let srcSkills = sourceDir.appendingPathComponent("skills")
            let dstSkills = dataURL.appendingPathComponent("skills")
            if fm.fileExists(atPath: srcSkills.path) {
                try? fm.removeItem(at: dstSkills)
                try fm.copyItem(at: srcSkills, to: dstSkills)
            }

            // Back up personal LoRA adapters produced by the improvement loop.
            let srcAdapters = sourceDir.appendingPathComponent("adapters")
            let dstAdapters = dataURL.appendingPathComponent("adapters")
            if fm.fileExists(atPath: srcAdapters.path) {
                try? fm.removeItem(at: dstAdapters)
                try fm.copyItem(at: srcAdapters, to: dstAdapters)
            }
        }

        return skippedDatabases
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
