// FaeEnvironment.swift
// Fae
//
// Central environment detection for dev-mode isolation.
// When FAE_DEV=1 or --dev is passed, Fae uses a completely separate data
// directory, UserDefaults suite, and vault path — leaving the production
// Fae instance untouched.

import Foundation

/// Environment context for the running Fae instance.
///
/// Dev mode uses separate data directories and UserDefaults to isolate
/// development/testing from the production Fae that the user runs daily.
///
/// Detection (checked once at process launch, immutable thereafter):
/// - Environment variable: `FAE_DEV=1`
/// - Command-line argument: `--dev`
enum FaeEnvironment {
    /// Whether this instance is running in development mode.
    ///
    /// When `true`:
    /// - Data directory: `~/Library/Application Support/fae-dev/`
    /// - Vault: `~/.fae-vault-dev/`
    /// - UserDefaults suite: `com.saorsalabs.fae-dev`
    /// - config.toml is read and written (developer tuning)
    /// - A "DEV" badge appears on the orb
    ///
    /// When `false` (normal mode):
    /// - Data directory: `~/Library/Application Support/fae/`
    /// - Vault: `~/.fae-vault/`
    /// - UserDefaults suite: standard
    /// - config.toml is NOT read (code defaults + UserDefaults only)
    /// - Clean user experience
    static let isDev: Bool = {
        if ProcessInfo.processInfo.environment["FAE_DEV"] == "1" {
            return true
        }
        if CommandLine.arguments.contains("--dev") {
            return true
        }
        return false
    }()

    /// Whether we're running inside XCTest (allows config persistence during tests).
    static let isTesting: Bool = {
        NSClassFromString("XCTestCase") != nil
    }()

    /// Display name for the current mode.
    static var modeName: String { isDev ? "Development" : "Production" }

    /// The UserDefaults store for this environment.
    ///
    /// Dev mode uses a separate suite so @AppStorage values don't
    /// interfere with the production instance.
    static let defaults: UserDefaults = {
        if isDev {
            return UserDefaults(suiteName: "com.saorsalabs.fae-dev") ?? .standard
        }
        return .standard
    }()
}

/// Centralised data directory paths for Fae.
///
/// Every subsystem that needs a file path should use these instead of
/// constructing paths from `applicationSupportDirectory` directly.
/// This ensures dev-mode isolation is consistent across the app.
///
/// ```swift
/// let dbPath = FaeDirectories.database.path       // fae.db
/// let configPath = FaeDirectories.configFile.path  // config.toml
/// ```
enum FaeDirectories {
    // MARK: - Root Directories

    /// Application Support base: `~/Library/Application Support/`
    private static let appSupport: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    }()

    /// Root data directory.
    /// - Normal: `~/Library/Application Support/fae/`
    /// - Dev: `~/Library/Application Support/fae-dev/`
    static let root: URL = {
        let name = FaeEnvironment.isDev ? "fae-dev" : "fae"
        let url = appSupport.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Git vault directory (outside Application Support — survives app deletion).
    /// - Normal: `~/.fae-vault/`
    /// - Dev: `~/.fae-vault-dev/`
    static let vault: URL = {
        let name = FaeEnvironment.isDev ? ".fae-vault-dev" : ".fae-vault"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(name)
    }()

    /// Cache directory.
    /// - Normal: `~/Library/Caches/fae/`
    /// - Dev: `~/Library/Caches/fae-dev/`
    static let cache: URL = {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches")
        let name = FaeEnvironment.isDev ? "fae-dev" : "fae"
        let url = base.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Config Files

    /// `config.toml` — only meaningful in dev mode.
    static let configFile: URL = root.appendingPathComponent("config.toml")

    /// `soul.md` — user's soul contract.
    static let soulFile: URL = root.appendingPathComponent("soul.md")

    /// `directive.md` — standing orders.
    static let directiveFile: URL = root.appendingPathComponent("directive.md")

    /// `heartbeat.md` — heartbeat document.
    static let heartbeatFile: URL = root.appendingPathComponent("heartbeat.md")

    // MARK: - Databases

    /// `fae.db` — main memory database.
    static let database: URL = root.appendingPathComponent("fae.db")

    /// `scheduler.db` — scheduler persistence.
    static let schedulerDatabase: URL = root.appendingPathComponent("scheduler.db")

    /// `tool_analytics.db` — tool usage analytics.
    static let toolAnalyticsDatabase: URL = root.appendingPathComponent("tool_analytics.db")

    // MARK: - JSON Stores

    /// `speakers.json` — speaker voice profiles.
    static let speakersFile: URL = root.appendingPathComponent("speakers.json")

    /// `wake_lexicon.json` — wake word profiles.
    static let wakeLexiconFile: URL = root.appendingPathComponent("wake_lexicon.json")

    /// `approved_tools.json` — progressive tool approval store.
    static let approvedToolsFile: URL = root.appendingPathComponent("approved_tools.json")

    /// `security-events.jsonl` — security event log.
    static let securityEventsFile: URL = root.appendingPathComponent("security-events.jsonl")

    /// `novel_recipients.json` — outbound exfiltration guard.
    static let novelRecipientsFile: URL = root.appendingPathComponent("novel_recipients.json")

    /// `roleplay_sessions.json` — active roleplay sessions.
    static let roleplaySessionsFile: URL = root.appendingPathComponent("roleplay_sessions.json")

    /// `roleplay_voices.json` — roleplay voice assignments.
    static let roleplayVoicesFile: URL = root.appendingPathComponent("roleplay_voices.json")

    // MARK: - Subdirectories

    /// `skills/` — user-created and imported skills.
    static let skillsDirectory: URL = root.appendingPathComponent("skills")

    /// `voices/` — custom voice files.
    static let voicesDirectory: URL = root.appendingPathComponent("voices")

    /// `recovery/` — reversibility engine checkpoints.
    static let recoveryDirectory: URL = root.appendingPathComponent("recovery")

    /// `models/` — downloaded ML models.
    static let modelsDirectory: URL = root.appendingPathComponent("models")

    /// `inbox/` — memory inbox for ingestion.
    static let inboxDirectory: URL = root.appendingPathComponent("inbox")

    // MARK: - Vault Blocked Path

    /// The vault path prefix for PathPolicy blocklist.
    /// Normal: `/.fae-vault`, Dev: `/.fae-vault-dev`
    static let vaultBlockedPathSuffix: String = FaeEnvironment.isDev ? "/.fae-vault-dev" : "/.fae-vault"
}
