import Foundation

/// Manages directory-based skills following the Agent Skills specification.
///
/// Skills are directories containing a `SKILL.md` entry point with YAML frontmatter.
/// Executable skills may include `scripts/`, `references/`, and `assets/`.
///
/// Discovery roots:
/// - Built-in: bundled in `Resources/Skills/`
/// - Personal: `~/Library/Application Support/fae/skills/`
/// - Shared/community: `~/.agents/skills/`, `./.agents/skills/`, `~/.fae-forge/tools/`
actor SkillManager {
    struct ConfigurableFieldDescriptor: Sendable {
        let id: String
        let label: String
        let required: Bool
        let prompt: String?
        let placeholder: String?
        let type: SkillSettingsFieldType
        let sensitive: Bool
        let store: SkillSettingsStore
        let validation: SkillSettingsValidation?
    }

    struct ConfigurableSkillDescriptor: Sendable {
        let name: String
        let kind: String
        let key: String
        let displayName: String
        let isEnabled: Bool
        let tier: SkillTier
        let actionNames: [String]
        let supportsDisconnect: Bool
        let requiredFieldIDs: [String]
        let fields: [ConfigurableFieldDescriptor]
    }

    private var runningProcesses: [String: Process] = [:]
    private var skillCache: [String: SkillMetadata] = [:]
    private var activatedBodies: [String: String] = [:]

    /// Skill directory: ~/Library/Application Support/fae/skills/
    static var skillsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/skills")
    }

    /// User-scoped shared Agent Skills directory.
    static var sharedSkillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills", isDirectory: true)
    }

    /// Project-scoped shared Agent Skills directory, when available.
    static var projectSkillsDirectory: URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardized
            .resolvingSymlinksInPath()
        return cwd.appendingPathComponent(".agents/skills", isDirectory: true)
    }

    /// Forge/Toolbox local tool registry output.
    static var forgeToolsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae-forge/tools", isDirectory: true)
    }

    /// Legacy flat-skill import directory.
    static var legacySkillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae/skills", isDirectory: true)
    }

    /// Audio input directory for skill file handoff.
    static var audioInputDirectory: URL {
        skillsDirectory.deletingLastPathComponent()
            .appendingPathComponent("skill_audio/input")
    }

    /// Audio output directory for skill file handoff.
    static var audioOutputDirectory: URL {
        skillsDirectory.deletingLastPathComponent()
            .appendingPathComponent("skill_audio/output")
    }

    /// Build audio context paths for skill execution (creates directories if needed).
    static func audioContextForSkill() -> [String: Any] {
        let inputDir = audioInputDirectory
        let outputDir = audioOutputDirectory
        try? FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        return [
            "audio_input_dir": inputDir.path,
            "audio_output_dir": outputDir.path,
        ]
    }

    static func discoveryRoots() -> [(url: URL, tier: SkillTier)] {
        var roots: [(URL, SkillTier)] = [
            (skillsDirectory, .personal),
            (sharedSkillsDirectory, .community),
            (forgeToolsDirectory, .community),
        ]

        if let projectSkillsDirectory {
            roots.append((projectSkillsDirectory, .community))
        }

        roots.append((legacySkillsDirectory, .community))

        var seen: Set<String> = []
        return roots.filter { entry in
            let canonical = entry.0.standardized.resolvingSymlinksInPath().path
            return seen.insert(canonical).inserted
        }
    }

    // MARK: - Discovery

    /// Discover all skills from built-in and personal directories.
    func discoverSkills() -> [SkillMetadata] {
        var merged: [String: SkillMetadata] = [:]
        skillCache.removeAll()

        // Built-in skills from app resource bundle.
        if let builtinDir = Bundle.faeResources.url(forResource: "Skills", withExtension: nil) {
            merge(
                scanDirectory(builtinDir, tier: .builtin),
                into: &merged
            )
        }

        for (dir, tier) in Self.discoveryRoots() {
            merge(scanDirectory(dir, tier: tier), into: &merged)
        }

        // Trust-level defaulting: executable skills are disabled unless manifest is valid.
        let all = merged.values
            .map { validatedMetadata(for: $0) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        for skill in all {
            skillCache[skill.name] = skill
        }
        return all
    }

    /// Return skill descriptions for progressive disclosure in the system prompt.
    ///
    /// Each entry is ~50-100 tokens. Full SKILL.md body loaded only on activation.
    func promptMetadata() -> [(name: String, description: String, type: SkillType)] {
        let skills = discoverSkills()
        return skills.filter(\.isEnabled).map { ($0.name, $0.description, $0.type) }
    }

    /// Return discovered skills that expose a settings contract.
    ///
    /// Used by Settings UI and channel orchestration for auto-discovery.
    /// Pass `kind: "channel"` to only retrieve channel-integrations.
    func configurableSkills(kind: String? = nil) -> [ConfigurableSkillDescriptor] {
        let allSkills = discoverSkills()
        let requestedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)

        var results: [ConfigurableSkillDescriptor] = []
        results.reserveCapacity(allSkills.count)

        for skill in allSkills {
            guard let manifest = try? loadManifest(for: skill),
                  let settings = manifest.settings
            else {
                continue
            }

            if let requestedKind,
               !requestedKind.isEmpty,
               settings.kind.caseInsensitiveCompare(requestedKind) != .orderedSame
            {
                continue
            }

            let actionNames = [
                settings.actions.status,
                settings.actions.configure,
                settings.actions.test,
                settings.actions.disconnect,
                settings.actions.sendSample,
            ].compactMap { $0 }

            let fields = settings.fields.map {
                ConfigurableFieldDescriptor(
                    id: $0.id,
                    label: $0.label,
                    required: $0.required,
                    prompt: $0.prompt,
                    placeholder: $0.placeholder,
                    type: $0.type,
                    sensitive: $0.sensitive ?? ($0.type == .secret),
                    store: $0.store ?? (($0.sensitive ?? ($0.type == .secret)) ? .secretStore : .configStore),
                    validation: $0.validation
                )
            }

            let requiredFieldIDs = fields
                .filter { $0.required }
                .map(\.id)

            results.append(
                ConfigurableSkillDescriptor(
                    name: skill.name,
                    kind: settings.kind,
                    key: settings.key,
                    displayName: settings.displayName,
                    isEnabled: skill.isEnabled,
                    tier: skill.tier,
                    actionNames: actionNames,
                    supportsDisconnect: settings.actions.disconnect != nil,
                    requiredFieldIDs: requiredFieldIDs,
                    fields: fields
                )
            )
        }

        return results
    }

    /// List installed skill names (static — no actor instance needed).
    ///
    /// Scans for both legacy flat `.py` files and v2 directory-based skills.
    static func installedSkillNames() -> [String] {
        let fm = FileManager.default
        var names: Set<String> = []

        for (dir, _) in discoveryRoots() {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for url in contents {
                if url.pathExtension == "py" {
                    names.insert(url.deletingPathExtension().lastPathComponent)
                    continue
                }

                if url.pathExtension == "md", url.lastPathComponent != "SKILL.md" {
                    names.insert(url.deletingPathExtension().lastPathComponent)
                    continue
                }

                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let skillMd = url.appendingPathComponent("SKILL.md")
                    if fm.fileExists(atPath: skillMd.path) {
                        names.insert(url.lastPathComponent)
                    }
                }
            }
        }

        return names.sorted()
    }

    // MARK: - Activation

    /// Activate a skill by name — loads the full SKILL.md body.
    ///
    /// Returns the body text for injection into the LLM context.
    func activate(skillName: String) -> String? {
        if let cached = activatedBodies[skillName] {
            guard let metadata = resolvedSkillMetadata(named: skillName),
                  metadata.isEnabled
            else {
                activatedBodies.removeValue(forKey: skillName)
                return nil
            }
            return cached
        }

        guard let metadata = resolvedSkillMetadata(named: skillName),
              metadata.isEnabled
        else {
            return nil
        }

        let skillMd = metadata.directoryURL.appendingPathComponent("SKILL.md")
        guard let record = SkillParser.parseRecord(
            skillURL: skillMd, tier: metadata.tier, isEnabled: metadata.isEnabled
        ) else {
            return nil
        }

        if let body = record.fullBody {
            activatedBodies[skillName] = body
            NSLog("SkillManager: activated skill '%@' (%d chars)", skillName, body.count)
            return body
        }
        return nil
    }

    /// Deactivate a skill — remove its body from the active context.
    func deactivate(skillName: String) {
        activatedBodies.removeValue(forKey: skillName)
    }

    /// All currently activated skill bodies for injection into context.
    func activatedContext() -> String? {
        guard !activatedBodies.isEmpty else { return nil }

        var activeEntries: [(String, String)] = []
        for skillName in activatedBodies.keys.sorted() {
            guard let metadata = resolvedSkillMetadata(named: skillName),
                  metadata.isEnabled,
                  let body = activatedBodies[skillName]
            else {
                activatedBodies.removeValue(forKey: skillName)
                continue
            }
            activeEntries.append((skillName, body))
        }

        guard !activeEntries.isEmpty else { return nil }
        return activeEntries
            .map { "[\($0.0) skill instructions]\n\($0.1)" }
            .joined(separator: "\n\n")
    }

    /// Names of skills that are currently active in the prompt/runtime context.
    func activatedSkillNames() -> [String] {
        guard !activatedBodies.isEmpty else { return [] }

        var activeNames: [String] = []
        for skillName in activatedBodies.keys.sorted() {
            guard let metadata = resolvedSkillMetadata(named: skillName),
                  metadata.isEnabled
            else {
                activatedBodies.removeValue(forKey: skillName)
                continue
            }
            activeNames.append(skillName)
        }
        return activeNames
    }

    // MARK: - Execution

    /// Execute a skill's Python script by name with the given input.
    ///
    /// - Parameters:
    ///   - skillName: The skill directory name.
    ///   - scriptName: Optional specific script name (without .py) for multi-script skills.
    ///   - input: JSON-serializable input dictionary.
    ///   - capabilityTicketId: Non-empty broker-issued ticket proving turn-scoped authorization.
    func execute(
        skillName: String,
        scriptName: String? = nil,
        input: [String: Any],
        capabilityTicketId: String,
        secretBindings: [String: String] = [:]
    ) async throws -> String {
        try Self.validateSkillName(skillName)

        guard !capabilityTicketId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillError.policyViolation("Missing capability ticket for run_skill execution")
        }

        if let (url, reason) = Self.firstBlockedURL(in: input) {
            throw SkillError.blockedNetworkTarget(url, reason)
        }

        guard let metadata = resolvedSkillMetadata(named: skillName) else {
            throw SkillError.notFound(skillName)
        }

        // Executable skills must provide a valid capability manifest.
        let manifest: SkillCapabilityManifest
        if metadata.type == .executable {
            manifest = try loadManifest(for: metadata)
        } else {
            manifest = SkillCapabilityManifest.conservativeDefault(for: metadata.type)
        }

        if !manifest.allowedDomains.isEmpty,
           let url = Self.firstDisallowedURL(in: input, allowedDomains: manifest.allowedDomains)
        {
            throw SkillError.invalidManifest(
                "Input URL '\(url)' is outside skill allowedDomains"
            )
        }

        // Execute only scripts from directory-based executable skills.
        guard let scriptPath = findExecutableScript(skillName: skillName, scriptName: scriptName),
              FileManager.default.fileExists(atPath: scriptPath)
        else {
            throw SkillError.notFound(skillName)
        }

        try Self.validateExecutableScriptPolicy(scriptPath: scriptPath, manifest: manifest)

        // Build JSON-RPC request with secret-sanitized params.
        let sanitizedInput = Self.sanitizeSkillInput(input)
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "execute",
            "params": sanitizedInput,
            "id": 1,
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let requestStr = String(data: requestData, encoding: .utf8)
        else {
            throw SkillError.serializationFailed
        }

        let timeoutSeconds = min(max(manifest.timeoutSeconds, 5), 120)
        let secretEnvironment = try Self.resolveSecretBindings(secretBindings)
        let handles = try SafeSkillExecutor.createProcess(
            skillName: skillName,
            scriptPath: scriptPath,
            timeoutSeconds: timeoutSeconds,
            additionalEnvironment: secretEnvironment
        )

        let process = handles.process
        let stdin = handles.stdin
        let stdout = handles.stdout
        let stderr = handles.stderr

        try process.run()
        runningProcesses[skillName] = process

        // Send request via stdin.
        guard let requestBytes = requestStr.data(using: .utf8) else {
            runningProcesses.removeValue(forKey: skillName)
            process.terminate()
            throw SkillError.serializationFailed
        }
        stdin.fileHandleForWriting.write(requestBytes)
        stdin.fileHandleForWriting.closeFile()

        let outputTask = Task<(Data, Data), Never> {
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return (outData, errData)
        }

        do {
            let status = try await SafeSkillExecutor.waitForExit(
                process: process,
                timeoutSeconds: timeoutSeconds
            )
            runningProcesses.removeValue(forKey: skillName)

            let (outData, errData) = await outputTask.value
            let output = String(data: outData, encoding: .utf8) ?? ""

            guard status == 0 else {
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                throw SkillError.executionFailed(skillName, errStr)
            }

            return output
        } catch {
            if process.isRunning {
                process.terminate()
            }
            runningProcesses.removeValue(forKey: skillName)
            _ = await outputTask.value
            throw error
        }
    }

    // MARK: - Skill Management (create, delete)

    /// Create a new personal skill directory with SKILL.md.
    func createSkill(
        name: String,
        description: String,
        body: String,
        scriptContent: String? = nil
    ) throws -> SkillMetadata {
        try Self.validateSkillName(name)
        try Self.validateSkillMetadata(name: name, description: description, body: body)
        if let script = scriptContent {
            try Self.validateScriptContent(script)
        }

        let skillDir = try Self.canonicalSkillDirectory(for: name)
        let fm = FileManager.default

        guard !fm.fileExists(atPath: skillDir.path) else {
            throw SkillError.alreadyExists(name)
        }

        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)

        // Write SKILL.md.
        let frontmatter = """
            ---
            name: \(name)
            description: \(description)
            metadata:
              author: user
              version: "1.0"
            ---
            """
        let fullContent = frontmatter + "\n" + body
        try fullContent.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        // If script content provided, create scripts/ directory and MANIFEST.json.
        if let script = scriptContent {
            let scriptsDir = skillDir.appendingPathComponent("scripts")
            try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            try script.write(
                to: scriptsDir.appendingPathComponent("\(name).py"),
                atomically: true, encoding: .utf8
            )

            let integrity = SkillManifestPolicy.buildIntegrity(for: skillDir)
            let manifest = SkillCapabilityManifest
                .conservativeDefault(for: .executable)
                .withIntegrity(integrity)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: SkillManifestPolicy.manifestURL(for: skillDir))
        }

        // Parse and cache the new skill.
        let skillMd = skillDir.appendingPathComponent("SKILL.md")
        guard let metadata = SkillParser.parse(skillURL: skillMd, tier: .personal) else {
            throw SkillError.invalidSkillMd(name)
        }
        skillCache[name] = metadata
        NSLog("SkillManager: created skill '%@'", name)
        return metadata
    }

    /// Update a personal skill's SKILL.md (description and/or body).
    ///
    /// Only personal-tier skills can be updated — built-in skills are immutable.
    /// At least one of `description` or `body` must be non-nil.
    func updateSkill(name: String, description: String?, body: String?) throws -> SkillMetadata {
        try Self.validateSkillName(name)

        guard let existing = skillCache[name] ?? lookupSkill(named: name) else {
            throw SkillError.notFound(name)
        }

        guard existing.tier == .personal else {
            throw SkillError.notPersonal(name)
        }

        let skillMdURL = existing.directoryURL.appendingPathComponent("SKILL.md")
        let currentContent = try String(contentsOf: skillMdURL, encoding: .utf8)

        // Split into frontmatter lines and body.
        let lines = currentContent.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces) == "---"
        else {
            throw SkillError.invalidSkillMd(name)
        }

        var closingIndex: Int?
        for i in 1 ..< lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }
        guard let endIdx = closingIndex else {
            throw SkillError.invalidSkillMd(name)
        }

        // Rebuild frontmatter lines, replacing description if provided.
        var frontmatterLines = Array(lines[1 ..< endIdx])
        if let newDesc = description {
            let trimmedDesc = newDesc.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDesc.count < 10 {
                throw SkillError.policyViolation("description is too short; include concrete behavior")
            }

            var replaced = false
            for i in 0 ..< frontmatterLines.count {
                let trimmed = frontmatterLines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("description:") {
                    frontmatterLines[i] = "description: \(trimmedDesc)"
                    replaced = true
                    break
                }
            }
            if !replaced {
                frontmatterLines.append("description: \(trimmedDesc)")
            }
        }

        // Rebuild the body — use new body if provided, otherwise keep existing.
        let existingBodyLines = Array(lines[(endIdx + 1)...])
        let existingBody = existingBodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalBody: String
        if let newBody = body {
            let trimmedBody = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.count < 20 {
                throw SkillError.policyViolation("SKILL.md body is too short")
            }

            let lowered = trimmedBody.lowercased()
            if lowered.contains("api key") || lowered.contains("token:") || lowered.contains("password:") {
                throw SkillError.policyViolation("skill body appears to contain credential-like content")
            }

            finalBody = trimmedBody
        } else {
            finalBody = existingBody
        }

        // Assemble updated SKILL.md content.
        var updatedContent = "---\n"
        updatedContent += frontmatterLines.joined(separator: "\n") + "\n"
        updatedContent += "---\n"
        updatedContent += finalBody + "\n"

        try updatedContent.write(to: skillMdURL, atomically: true, encoding: .utf8)

        // Re-parse and update cache.
        guard let updatedMetadata = SkillParser.parse(
            skillURL: skillMdURL, tier: .personal, isEnabled: existing.isEnabled
        ) else {
            throw SkillError.invalidSkillMd(name)
        }

        skillCache[name] = updatedMetadata

        // If this skill was activated, refresh the body cache.
        if activatedBodies[name] != nil {
            let record = SkillParser.parseRecord(
                skillURL: skillMdURL, tier: .personal, isEnabled: existing.isEnabled
            )
            if let refreshedBody = record?.fullBody {
                activatedBodies[name] = refreshedBody
            }
        }

        NSLog("SkillManager: updated skill '%@'", name)
        return updatedMetadata
    }

    /// Delete a personal skill directory.
    func deleteSkill(name: String) throws {
        try Self.validateSkillName(name)
        let skillDir = try Self.canonicalSkillDirectory(for: name)
        guard FileManager.default.fileExists(atPath: skillDir.path) else {
            throw SkillError.notFound(name)
        }
        try FileManager.default.removeItem(at: skillDir)
        skillCache.removeValue(forKey: name)
        activatedBodies.removeValue(forKey: name)
        NSLog("SkillManager: deleted skill '%@'", name)
    }

    // MARK: - Health Check

    /// Check health of all running skill processes.
    func healthCheck() -> [String: Bool] {
        var status: [String: Bool] = [:]
        for (name, process) in runningProcesses {
            status[name] = process.isRunning
        }
        return status
    }

    /// Validate all discovered skills.
    func healthCheckAll() -> [String: SkillHealthStatus] {
        let skills = discoverSkills()
        var results: [String: SkillHealthStatus] = [:]
        let fm = FileManager.default

        for skill in skills {
            let skillMd = skill.directoryURL.appendingPathComponent("SKILL.md")
            if !fm.fileExists(atPath: skillMd.path) {
                results[skill.name] = .broken("Missing SKILL.md")
                continue
            }

            if skill.type == .executable {
                let scriptsDir = skill.directoryURL.appendingPathComponent("scripts")
                if !fm.fileExists(atPath: scriptsDir.path) {
                    results[skill.name] = .degraded("Missing scripts/ directory")
                    continue
                }

                let manifestURL = SkillManifestPolicy.manifestURL(for: skill.directoryURL)
                if !fm.fileExists(atPath: manifestURL.path) {
                    results[skill.name] = .degraded("Missing MANIFEST.json (running with conservative defaults)")
                    continue
                }
            }

            results[skill.name] = .healthy
        }
        return results
    }

    // MARK: - Private Helpers

    private func scanDirectory(_ dir: URL, tier: SkillTier) -> [SkillMetadata] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var results: [SkillMetadata] = []
        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let skillMd = url.appendingPathComponent("SKILL.md")
            if let metadata = SkillParser.parse(skillURL: skillMd, tier: tier) {
                results.append(metadata)
            }
        }
        return results
    }

    private func merge(_ discovered: [SkillMetadata], into merged: inout [String: SkillMetadata]) {
        for metadata in discovered {
            if let existing = merged[metadata.name] {
                let existingRank = Self.tierPriority(existing.tier)
                let newRank = Self.tierPriority(metadata.tier)
                if newRank >= existingRank {
                    merged[metadata.name] = metadata
                }
            } else {
                merged[metadata.name] = metadata
            }
        }
    }

    private static func tierPriority(_ tier: SkillTier) -> Int {
        switch tier {
        case .builtin:
            return 0
        case .community:
            return 1
        case .personal:
            return 2
        }
    }

    private func lookupSkill(named name: String) -> SkillMetadata? {
        guard Self.isSafeSkillName(name) else { return nil }
        if let builtinDir = Bundle.faeResources.url(forResource: "Skills", withExtension: nil) {
            let builtinSkillDir = builtinDir.appendingPathComponent(name)
            let builtinMd = builtinSkillDir.appendingPathComponent("SKILL.md")
            if let metadata = SkillParser.parse(skillURL: builtinMd, tier: .builtin) {
                return validatedMetadata(for: metadata)
            }
        }

        for (root, tier) in Self.discoveryRoots() {
            let skillDir = root.appendingPathComponent(name)
            let skillMd = skillDir.appendingPathComponent("SKILL.md")
            if let metadata = SkillParser.parse(skillURL: skillMd, tier: tier) {
                return validatedMetadata(for: metadata)
            }
        }

        return nil
    }

    private func resolvedSkillMetadata(named name: String) -> SkillMetadata? {
        guard let metadata = skillCache[name] ?? lookupSkill(named: name) else {
            return nil
        }

        let validated = validatedMetadata(for: metadata)
        skillCache[name] = validated
        return validated
    }

    private func validatedMetadata(for metadata: SkillMetadata) -> SkillMetadata {
        guard metadata.type == .executable else {
            return metadata
        }

        var adjusted = metadata
        do {
            _ = try loadManifest(for: metadata)
        } catch SkillError.missingManifest {
            return adjusted
        } catch {
            adjusted.isEnabled = false
            NSLog("SkillManager: disabling executable skill '%@' — invalid/missing manifest", metadata.name)
        }
        return adjusted
    }

    private func loadManifest(for metadata: SkillMetadata) throws -> SkillCapabilityManifest {
        let manifestURL = SkillManifestPolicy.manifestURL(for: metadata.directoryURL)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return SkillCapabilityManifest.conservativeDefault(for: metadata.type)
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SkillCapabilityManifest.self, from: data)
        try Self.validateManifest(manifest, for: metadata.type)

        if let integrity = manifest.integrity,
           let error = SkillManifestPolicy.verifyIntegrity(
               integrity,
               skillDirectory: metadata.directoryURL
           )
        {
            throw SkillError.policyViolation(error)
        }

        return manifest
    }

    private static func validateManifest(_ manifest: SkillCapabilityManifest, for type: SkillType) throws {
        guard manifest.schemaVersion == SkillCapabilityManifest.currentSchemaVersion else {
            throw SkillError.invalidManifest(
                "schemaVersion=\(manifest.schemaVersion), expected \(SkillCapabilityManifest.currentSchemaVersion)"
            )
        }

        guard (5...600).contains(manifest.timeoutSeconds) else {
            throw SkillError.invalidManifest("timeoutSeconds must be within 5...600")
        }

        guard !manifest.capabilities.isEmpty else {
            throw SkillError.invalidManifest("capabilities must not be empty")
        }

        if let settings = manifest.settings {
            try validateSettingsContract(settings, capabilities: manifest.capabilities)
        }

        if type == .executable {
            guard manifest.capabilities.contains("execute") else {
                throw SkillError.invalidManifest("executable skills must declare capability 'execute'")
            }
            guard manifest.allowedTools.contains("run_skill") else {
                throw SkillError.invalidManifest("executable skills must include allowedTools: run_skill")
            }
            guard let integrity = manifest.integrity,
                  !integrity.checksums.isEmpty
            else {
                throw SkillError.invalidManifest(
                    "executable skills must include integrity checksums"
                )
            }
        }
    }

    private static func validateSettingsContract(
        _ settings: SkillSettingsContract,
        capabilities: [String]
    ) throws {
        guard settings.version >= 1 else {
            throw SkillError.invalidManifest("settings.version must be >= 1")
        }
        guard !settings.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillError.invalidManifest("settings.key must not be empty")
        }
        guard !settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillError.invalidManifest("settings.display_name must not be empty")
        }

        var seenFieldIds: Set<String> = []
        for field in settings.fields {
            let fieldID = field.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fieldID.isEmpty else {
                throw SkillError.invalidManifest("settings.fields[].id must not be empty")
            }
            if seenFieldIds.contains(fieldID) {
                throw SkillError.invalidManifest("settings field ids must be unique: \(fieldID)")
            }
            seenFieldIds.insert(fieldID)

            guard !field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkillError.invalidManifest("settings.fields[\(fieldID)].label must not be empty")
            }

            if field.type == .secret, field.defaultValue != nil {
                throw SkillError.invalidManifest("settings.fields[\(fieldID)] secret fields cannot define default values")
            }

            if let options = field.options,
               !options.isEmpty,
               !(field.type == .select || field.type == .multiselect)
            {
                throw SkillError.invalidManifest("settings.fields[\(fieldID)] options are only valid for select/multiselect")
            }
        }

        let declared = Set(capabilities)
        func ensureAction(_ action: String?) throws {
            guard let action else { return }
            guard declared.contains(action) else {
                throw SkillError.invalidManifest("settings action '\(action)' must be present in capabilities")
            }
        }

        try ensureAction(settings.actions.status)
        try ensureAction(settings.actions.configure)
        try ensureAction(settings.actions.test)
        try ensureAction(settings.actions.disconnect)
        try ensureAction(settings.actions.sendSample)
    }

    /// Find a Python script in a skill's scripts/ directory.
    ///
    /// If `scriptName` is provided, looks for `scripts/{scriptName}.py`.
    /// Otherwise returns the first `.py` file found.
    private func findExecutableScript(skillName: String, scriptName: String? = nil) -> String? {
        guard Self.isSafeSkillName(skillName),
              let metadata = resolvedSkillMetadata(named: skillName)
        else { return nil }
        let fm = FileManager.default

        func findIn(scriptsDir: URL) -> String? {
            if let specific = scriptName {
                let target = scriptsDir.appendingPathComponent("\(specific).py")
                return fm.fileExists(atPath: target.path) ? target.path : nil
            }
            guard let scripts = try? fm.contentsOfDirectory(
                at: scriptsDir, includingPropertiesForKeys: nil
            ) else { return nil }
            return scripts.first(where: { $0.pathExtension == "py" })?.path
        }

        let skillScripts = metadata.directoryURL
            .appendingPathComponent("scripts")
        return findIn(scriptsDir: skillScripts)
    }

    private static func validateSkillName(_ name: String) throws {
        guard isSafeSkillName(name) else {
            throw SkillError.invalidName(name)
        }
    }

    private static func validateSkillMetadata(name: String, description: String, body: String) throws {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
            throw SkillError.policyViolation("description is too short; include concrete behavior")
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            throw SkillError.policyViolation("SKILL.md body is too short")
        }

        let lowered = body.lowercased()
        if lowered.contains("api key") || lowered.contains("token:") || lowered.contains("password:") {
            throw SkillError.policyViolation("skill body appears to contain credential-like content")
        }

        if name.lowercased().contains("../") || name.contains("/") {
            throw SkillError.policyViolation("skill name contains invalid path characters")
        }
    }

    private static func validateScriptContent(_ script: String) throws {
        let forbiddenPatterns: [String] = [
            "os.system(",
            "subprocess.popen(",
            "pty.spawn(",
            "eval(",
            "exec(",
        ]

        let lowered = script.lowercased()
        for pattern in forbiddenPatterns where lowered.contains(pattern) {
            throw SkillError.policyViolation(
                "script content failed safety lint: forbidden pattern '\(pattern)'"
            )
        }
    }

    private static func validateExecutableScriptPolicy(
        scriptPath: String,
        manifest: SkillCapabilityManifest
    ) throws {
        let content = try String(contentsOfFile: scriptPath, encoding: .utf8).lowercased()

        if manifest.allowNetwork != true,
           networkIndicators.contains(where: { content.contains($0) })
        {
            throw SkillError.policyViolation(
                "Executable skill requests raw network access but MANIFEST.json does not allow it"
            )
        }

        if manifest.allowSubprocess != true,
           subprocessIndicators.contains(where: { content.contains($0) })
        {
            throw SkillError.policyViolation(
                "Executable skill requests subprocess access but MANIFEST.json does not allow it"
            )
        }
    }

    private static let networkIndicators: [String] = [
        "import socket",
        "from socket import",
        "import urllib",
        "from urllib",
        "urllib.request",
        "urllib3",
        "import requests",
        "from requests",
        "import httpx",
        "import aiohttp",
        "import websockets",
        "http.client",
    ]

    private static let subprocessIndicators: [String] = [
        "import subprocess",
        "from subprocess import",
        "subprocess.",
        "os.system(",
        "pty.spawn(",
        "import pexpect",
    ]

    /// Conservative skill-name validation to prevent path traversal and
    /// ambiguous filesystem behavior.
    private static func isSafeSkillName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed.contains("\\") { return false }
        if trimmed.contains("..") || trimmed.contains("~") { return false }

        // Allow: letters, numbers, underscore, hyphen.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Resolve skill directory and verify it remains within skills root even
    /// after symlink/canonical path resolution.
    private static func canonicalSkillDirectory(for name: String) throws -> URL {
        let root = skillsDirectory.standardized.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(name).standardized.resolvingSymlinksInPath()

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw SkillError.invalidName(name)
        }
        return candidate
    }

    /// Remove obvious secret material from skill input payloads.
    private static func sanitizeSkillInput(_ input: [String: Any]) -> [String: Any] {
        sanitizeAny(input) as? [String: Any] ?? [:]
    }

    private static func resolveSecretBindings(_ bindings: [String: String]) throws -> [String: String] {
        var resolved: [String: String] = [:]

        for (envName, keychainKey) in bindings {
            guard isSafeEnvironmentVariableName(envName) else {
                throw SkillError.policyViolation("Invalid secret env name '\(envName)'")
            }

            guard let value = CredentialManager.retrieve(key: keychainKey), !value.isEmpty else {
                throw SkillError.policyViolation("Missing stored secret '\(keychainKey)'")
            }

            resolved[envName] = value
        }

        return resolved
    }

    private static func isSafeEnvironmentVariableName(_ value: String) -> Bool {
        let pattern = "^[A-Z][A-Z0-9_]{1,63}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func sanitizeAny(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, val) in dict {
                if isSensitiveKey(key) {
                    out[key] = "[REDACTED_SECRET]"
                } else {
                    out[key] = sanitizeAny(val)
                }
            }
            return out
        }

        if let array = value as? [Any] {
            return array.map { sanitizeAny($0) }
        }

        if let string = value as? String,
           SensitiveDataRedactor.redact(string) != string
        {
            return "[REDACTED_SECRET]"
        }

        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("token")
            || lowered.contains("secret")
            || lowered.contains("password")
            || lowered.contains("api_key")
            || lowered.contains("apikey")
            || lowered == "key"
    }

    /// Scan skill input for URL strings and detect domain-allowlist violations.
    private static func firstDisallowedURL(in value: Any, allowedDomains: [String]) -> String? {
        if let string = value as? String,
           (string.hasPrefix("http://") || string.hasPrefix("https://")),
           let host = URL(string: string)?.host?.lowercased()
        {
            let allowed = allowedDomains.map { $0.lowercased() }
            let isAllowed = allowed.contains { host == $0 || host.hasSuffix("." + $0) }
            if !isAllowed {
                return string
            }
            return nil
        }

        if let dict = value as? [String: Any] {
            for item in dict.values {
                if let disallowed = firstDisallowedURL(in: item, allowedDomains: allowedDomains) {
                    return disallowed
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let disallowed = firstDisallowedURL(in: item, allowedDomains: allowedDomains) {
                    return disallowed
                }
            }
        }

        return nil
    }

    /// Scan skill input for URL strings and block local/private targets.
    private static func firstBlockedURL(in value: Any) -> (url: String, reason: String)? {
        if let string = value as? String,
           (string.hasPrefix("http://") || string.hasPrefix("https://"))
        {
            if let reason = NetworkTargetPolicy.blockedReason(urlString: string) {
                return (string, reason)
            }
            return nil
        }

        if let dict = value as? [String: Any] {
            for item in dict.values {
                if let blocked = firstBlockedURL(in: item) {
                    return blocked
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let blocked = firstBlockedURL(in: item) {
                    return blocked
                }
            }
        }

        return nil
    }

    enum SkillError: LocalizedError {
        case notFound(String)
        case serializationFailed
        case executionFailed(String, String)
        case timedOut(Int)
        case alreadyExists(String)
        case invalidSkillMd(String)
        case invalidName(String)
        case notPersonal(String)
        case blockedNetworkTarget(String, String)
        case missingManifest(String)
        case invalidManifest(String)
        case policyViolation(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name): return "Skill not found: \(name)"
            case .serializationFailed: return "Failed to serialize skill request"
            case .executionFailed(let name, let err): return "Skill '\(name)' failed: \(err)"
            case .timedOut(let seconds): return "Skill timed out after \(seconds)s"
            case .alreadyExists(let name): return "Skill '\(name)' already exists"
            case .invalidSkillMd(let name): return "Invalid SKILL.md for skill '\(name)'"
            case .invalidName(let name): return "Invalid skill name '\(name)'"
            case .notPersonal(let name):
                return "Skill '\(name)' is built-in and cannot be modified"
            case .blockedNetworkTarget(let url, let reason):
                return "Blocked network target in skill input (\(url)): \(reason)"
            case .missingManifest(let name):
                return "Executable skill '\(name)' is missing MANIFEST.json"
            case .invalidManifest(let details):
                return "Invalid skill manifest: \(details)"
            case .policyViolation(let details):
                return "Skill failed install policy checks: \(details)"
            }
        }
    }
}
