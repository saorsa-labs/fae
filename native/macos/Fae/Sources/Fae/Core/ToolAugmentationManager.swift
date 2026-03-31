import Foundation

/// Manages discovery and installation of CLI tools that augment Fae's capabilities.
///
/// Checks for fast search, code intelligence, and development tools on the system,
/// tracks availability, and provides install methods. The LLM is informed about
/// available tools via memory records so it can prefer them (e.g., `fd` over `find`).
enum ToolAugmentationManager {

    // MARK: - Tool Registry

    /// A CLI tool that augments Fae's capabilities.
    struct CLITool: Sendable {
        let name: String
        let binary: String
        let description: String
        let brewFormula: String?
        let category: Category
        let tier: Tier

        enum Category: String, Sendable {
            case search = "search"
            case data = "data"
            case code = "code"
            case git = "git"
            case media = "media"
            case agent = "agent"
        }

        /// Installation priority.
        enum Tier: Int, Sendable, Comparable {
            case core = 0      // Install proactively — high impact
            case extended = 1  // Install on demand

            static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
        }
    }

    /// All tools Fae benefits from having available.
    static let registry: [CLITool] = [
        // Tier 0 — Core (high impact, always useful)
        CLITool(name: "fd", binary: "fd", description: "Fast file finder (replaces find)",
                brewFormula: "fd", category: .search, tier: .core),
        CLITool(name: "ripgrep", binary: "rg", description: "Fast text search (replaces grep)",
                brewFormula: "ripgrep", category: .search, tier: .core),
        CLITool(name: "jq", binary: "jq", description: "JSON processor",
                brewFormula: "jq", category: .data, tier: .core),
        CLITool(name: "GitHub CLI", binary: "gh", description: "GitHub issues, PRs, repos",
                brewFormula: "gh", category: .git, tier: .core),
        CLITool(name: "tree", binary: "tree", description: "Directory structure viewer",
                brewFormula: "tree", category: .code, tier: .core),
        CLITool(name: "bat", binary: "bat", description: "Cat with syntax highlighting",
                brewFormula: "bat", category: .code, tier: .core),

        // Tier 1 — Extended (install on demand)
        CLITool(name: "tokei", binary: "tokei", description: "Code statistics by language",
                brewFormula: "tokei", category: .code, tier: .extended),
        CLITool(name: "ffmpeg", binary: "ffmpeg", description: "Audio and video processing",
                brewFormula: "ffmpeg", category: .media, tier: .extended),
        CLITool(name: "pandoc", binary: "pandoc", description: "Document format conversion",
                brewFormula: "pandoc", category: .media, tier: .extended),
        CLITool(name: "yq", binary: "yq", description: "YAML processor",
                brewFormula: "yq", category: .data, tier: .extended),
        CLITool(name: "delta", binary: "delta", description: "Better git diffs",
                brewFormula: "git-delta", category: .git, tier: .extended),
        CLITool(name: "ImageMagick", binary: "magick", description: "Image processing",
                brewFormula: "imagemagick", category: .media, tier: .extended),
    ]

    // MARK: - Discovery

    /// Cached tool check results (refreshed every 5 minutes).
    private static let cache = ToolCache()

    /// Check which tools are installed. Returns binary name → absolute path.
    /// Results are cached for 5 minutes to avoid spawning processes on every LLM turn.
    static func checkInstalled() -> [String: String] {
        if let cached = cache.get() { return cached }
        var results: [String: String] = [:]
        for tool in registry {
            if let path = whichBinary(tool.binary) {
                results[tool.binary] = path
            }
        }
        cache.set(results)
        return results
    }

    /// Force a fresh check (e.g., after installing new tools).
    static func invalidateCache() {
        cache.invalidate()
    }

    /// Detect the available package manager (zb or brew).
    static func packageManagerBinary() -> String? {
        if whichBinary("zb") != nil { return "zb" }
        if whichBinary("brew") != nil { return "brew" }
        return nil
    }

    /// Build a formatted summary of available tools for memory storage.
    static func availableToolsSummary(installed: [String: String]) -> String {
        guard !installed.isEmpty else {
            return "No augmented CLI tools detected. Standard macOS tools only (find, grep, cat)."
        }

        var lines: [String] = ["CLI tools available on this Mac (prefer these over slower alternatives):"]
        let sortedTools = registry.filter { installed[$0.binary] != nil }
            .sorted { $0.category.rawValue < $1.category.rawValue }

        var currentCategory: CLITool.Category?
        for tool in sortedTools {
            if tool.category != currentCategory {
                currentCategory = tool.category
            }
            let hint: String
            switch tool.binary {
            case "fd": hint = " — use instead of find"
            case "rg": hint = " — use instead of grep"
            case "bat": hint = " — use instead of cat for code"
            case "jq": hint = " — pipe JSON through jq for parsing"
            case "gh": hint = " — use for GitHub operations (issues, PRs, repos, releases)"
            default: hint = ""
            }
            lines.append("- \(tool.binary): \(tool.description)\(hint)")
        }

        let missing = registry.filter { $0.tier == .core && installed[$0.binary] == nil }
        if !missing.isEmpty {
            lines.append("")
            lines.append("Missing core tools (install with \(packageManagerBinary() ?? "brew")):")
            for tool in missing {
                if let formula = tool.brewFormula {
                    lines.append("- \(packageManagerBinary() ?? "brew") install \(formula)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build a compact prompt fragment telling the LLM about available tools.
    static func promptFragment(installed: [String: String]) -> String? {
        guard !installed.isEmpty else { return nil }

        var hints: [String] = []
        if installed["fd"] != nil { hints.append("fd (fast find)") }
        if installed["rg"] != nil { hints.append("rg (fast grep)") }
        if installed["jq"] != nil { hints.append("jq (JSON)") }
        if installed["gh"] != nil { hints.append("gh (GitHub CLI)") }
        if installed["bat"] != nil { hints.append("bat (syntax cat)") }
        if installed["tree"] != nil { hints.append("tree") }
        if installed["tokei"] != nil { hints.append("tokei (code stats)") }
        if installed["ffmpeg"] != nil { hints.append("ffmpeg") }

        guard !hints.isEmpty else { return nil }

        return """
            Fast CLI tools installed: \(hints.joined(separator: ", ")). \
            Prefer fd over find, rg over grep, bat over cat when viewing code. \
            Use gh for GitHub operations (repos, issues, PRs).
            """
    }

    // MARK: - Installation

    /// Install a tool by binary name. Returns true on success.
    @discardableResult
    static func install(binary: String) async -> Bool {
        guard let tool = registry.first(where: { $0.binary == binary }),
              let formula = tool.brewFormula,
              let pm = packageManagerBinary()
        else { return false }

        NSLog("ToolAugmentation: installing %@ via %@", binary, pm)
        let command = "\(pm) install \(formula)"
        do {
            let result = try await SafeBashExecutor.execute(command: command, timeoutSeconds: 120)
            if result.status == 0 {
                NSLog("ToolAugmentation: installed %@ successfully", binary)
                invalidateCache()
                return true
            } else {
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                NSLog("ToolAugmentation: failed to install %@: %@", binary, stderr)
                return false
            }
        } catch {
            NSLog("ToolAugmentation: install error for %@: %@", binary, error.localizedDescription)
            return false
        }
    }

    /// Install all core tier tools that are missing.
    static func installCoreTier() async -> [String] {
        let installed = checkInstalled()
        let missing = registry.filter { $0.tier == .core && installed[$0.binary] == nil }
        var newlyInstalled: [String] = []
        for tool in missing {
            if await install(binary: tool.binary) {
                newlyInstalled.append(tool.binary)
            }
        }
        return newlyInstalled
    }

    // MARK: - Helpers

    /// Resolve a binary name to its absolute path, or nil if not found.
    @discardableResult
    private static func whichBinary(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let home = NSHomeDirectory()
        process.environment = [
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.cargo/bin",
            "HOME": home,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Workspace Discovery

extension ToolAugmentationManager {

    /// Discovered project on disk.
    struct DiscoveredProject: Sendable {
        let name: String
        let path: String
        let projectType: String?
        let gitRemote: String?
    }

    /// Scan the filesystem for git repositories. Uses `fd` if available, falls back to FileManager.
    static func discoverProjects() -> [DiscoveredProject] {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // Scan roots — common project locations on any Mac.
        let scanRoots: [String] = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Developer",
            "\(home)/Projects",
            "\(home)/Code",
            "\(home)/repos",
            "\(home)/src",
            "\(home)/workspace",
            "\(home)/work",
            "\(home)/dev",
            "\(home)/github",
            "\(home)/git",
        ]

        // Also scan ~ direct children (depth 1).
        let homeChildren = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        let homeGitDirs = homeChildren.compactMap { entry -> String? in
            let full = "\(home)/\(entry)"
            // Skip known non-project dirs and hidden dirs (except dotfile projects).
            let skip = ["Library", "Applications", "Movies", "Music", "Pictures",
                        "Public", ".Trash", ".cache", ".npm", ".cargo", ".rustup",
                        ".docker", ".local", ".config"]
            if skip.contains(entry) { return nil }
            if fm.fileExists(atPath: "\(full)/.git") { return full }
            return nil
        }

        var gitDirs: Set<String> = Set(homeGitDirs)

        // Try fd first (much faster for deep scans).
        if let fdPath = whichBinary("fd") {
            for root in scanRoots where fm.fileExists(atPath: root) {
                if let found = fdScanForGitDirs(fdPath: fdPath, root: root, maxDepth: 4) {
                    gitDirs.formUnion(found)
                }
            }
        } else {
            // Fallback: FileManager scan (max depth 3).
            for root in scanRoots where fm.fileExists(atPath: root) {
                fileManagerScan(root: root, maxDepth: 3, results: &gitDirs)
            }
        }

        // Build project records.
        return gitDirs.map { projectPath in
            let name = URL(fileURLWithPath: projectPath).lastPathComponent
            let projectType = detectProjectType(at: projectPath)
            let remote = extractGitRemote(at: projectPath)
            return DiscoveredProject(name: name, path: projectPath, projectType: projectType, gitRemote: remote)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Use fd to find .git directories under a root.
    private static func fdScanForGitDirs(fdPath: String, root: String, maxDepth: Int) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fdPath)
        // fd --type d --hidden --no-ignore --max-depth N '^\.git$' <root>
        process.arguments = [
            "--type", "d", "--hidden", "--no-ignore",
            "--max-depth", String(maxDepth),
            "^\\.git$", root,
        ]
        process.environment = ["HOME": NSHomeDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").compactMap { line in
                let gitDir = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard gitDir.hasSuffix("/.git") else { return nil }
                // Return parent directory (the project root).
                return String(gitDir.dropLast(5))
            }
        } catch {
            return nil
        }
    }

    /// Fallback: recursively scan using FileManager.
    private static func fileManagerScan(root: String, maxDepth: Int, results: inout Set<String>) {
        guard maxDepth > 0 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return }

        let skipDirs: Set<String> = [
            "node_modules", ".build", "target", "build", "dist", ".cache",
            "Pods", "DerivedData", ".gradle", "__pycache__", ".venv", "venv",
        ]

        for entry in entries {
            if entry.hasPrefix(".") && entry != ".git" { continue }
            let fullPath = "\(root)/\(entry)"

            if entry == ".git" {
                results.insert(root)
                return // This root is a project; don't recurse deeper.
            }

            if skipDirs.contains(entry) { continue }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                fileManagerScan(root: fullPath, maxDepth: maxDepth - 1, results: &results)
            }
        }
    }

    /// Detect project type from manifest files.
    private static func detectProjectType(at path: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/Cargo.toml") { return "Rust" }
        if fm.fileExists(atPath: "\(path)/Package.swift") { return "Swift" }
        if fm.fileExists(atPath: "\(path)/package.json") {
            // Check for TypeScript.
            if fm.fileExists(atPath: "\(path)/tsconfig.json") { return "TypeScript" }
            return "JavaScript"
        }
        if fm.fileExists(atPath: "\(path)/pyproject.toml") || fm.fileExists(atPath: "\(path)/setup.py") {
            return "Python"
        }
        if fm.fileExists(atPath: "\(path)/go.mod") { return "Go" }
        if fm.fileExists(atPath: "\(path)/pom.xml") || fm.fileExists(atPath: "\(path)/build.gradle") ||
           fm.fileExists(atPath: "\(path)/build.gradle.kts") { return "Java" }
        if fm.fileExists(atPath: "\(path)/CMakeLists.txt") { return "C/C++" }
        if fm.fileExists(atPath: "\(path)/Makefile") { return "Make" }
        if fm.fileExists(atPath: "\(path)/Gemfile") { return "Ruby" }
        if fm.fileExists(atPath: "\(path)/mix.exs") { return "Elixir" }
        if fm.fileExists(atPath: "\(path)/pubspec.yaml") { return "Dart/Flutter" }
        return nil
    }

    /// Extract the first git remote URL from .git/config.
    private static func extractGitRemote(at path: String) -> String? {
        let configPath = "\(path)/.git/config"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }

        // Parse: [remote "origin"]\n\turl = <url>
        let lines = content.components(separatedBy: .newlines)
        var inRemote = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[remote") {
                inRemote = true
                continue
            }
            if trimmed.hasPrefix("[") {
                inRemote = false
                continue
            }
            if inRemote, trimmed.hasPrefix("url = ") || trimmed.hasPrefix("url=") {
                let url = trimmed
                    .replacingOccurrences(of: "url = ", with: "")
                    .replacingOccurrences(of: "url=", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return url.isEmpty ? nil : url
            }
        }
        return nil
    }

    /// Format discovered projects as a memory-friendly text block.
    static func formatProjectsForMemory(_ projects: [DiscoveredProject]) -> String {
        guard !projects.isEmpty else { return "No git projects found on this Mac." }

        var lines = ["Local development projects on this Mac:"]
        for project in projects {
            var parts = [project.name]
            if let ptype = project.projectType { parts.append("(\(ptype))") }
            parts.append("— \(project.path)")
            if let remote = project.gitRemote {
                // Clean up git remote for readability.
                let clean = remote
                    .replacingOccurrences(of: "git@github.com:", with: "github.com/")
                    .replacingOccurrences(of: ".git", with: "")
                parts.append("[\(clean)]")
            }
            lines.append("- " + parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cache

/// Thread-safe timed cache for tool check results.
final class ToolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [String: String]?
    private var cachedAt: Date?
    private let ttl: TimeInterval = 300 // 5 minutes

    func get() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached, let at = cachedAt, Date().timeIntervalSince(at) < ttl else { return nil }
        return cached
    }

    func set(_ value: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        cached = value
        cachedAt = Date()
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        cachedAt = nil
    }
}
