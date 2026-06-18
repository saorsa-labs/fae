import CryptoKit
import Foundation

/// Optional cascaded STT lane for B5 audio hardening.
///
/// This is an interface/scaffold until an approved Qwen3-ASR or whisper asset is
/// added to `models.lock`. Runtime environment can select paths and artifact
/// ids, but the expected SHA-256 values must come from the trusted lock file —
/// never from the same environment that supplies the path.
protocol AudioFallbackTranscribing: Sendable {
    func transcribe(audioWAVBase64: String) async -> String?
}

enum AudioFallbackMode: String, Sendable {
    /// Only try fallback after the primary transcript fails the quality gate.
    case qualityFail = "quality_fail"
    /// Try fallback after a quality failure or for fragile short/dictation turns.
    case fragile = "fragile"
    /// Always prefer a verified fallback transcript when one is produced.
    case always = "always"

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AudioFallbackMode {
        guard let raw = environment["FAE_AUDIO_FALLBACK_MODE"]?.lowercased(), !raw.isEmpty else {
            return .fragile
        }
        return AudioFallbackMode(rawValue: raw) ?? .fragile
    }
}

struct AudioFallbackLockArtifact: Sendable, Equatable {
    let id: String
    let sha256: String
}

struct AudioFallbackModelsLock: Sendable {
    let artifactsByID: [String: AudioFallbackLockArtifact]

    static func load(from url: URL) -> AudioFallbackModelsLock? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Minimal parser for Fae's `models.lock` artifact blocks. We only need
    /// `id` and `sha256`; malformed or incomplete blocks are ignored.
    static func parse(_ text: String) -> AudioFallbackModelsLock {
        var artifacts: [String: AudioFallbackLockArtifact] = [:]
        var current: [String: String] = [:]

        func flush() {
            guard let id = current["id"], let sha = current["sha256"], !id.isEmpty, !sha.isEmpty else {
                current.removeAll()
                return
            }
            artifacts[id] = AudioFallbackLockArtifact(id: id, sha256: sha)
            current.removeAll()
        }

        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "[[artifact]]" {
                flush()
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            current[String(key)] = String(value)
        }
        flush()
        return AudioFallbackModelsLock(artifactsByID: artifacts)
    }

    func sha256(for id: String) -> String? {
        artifactsByID[id]?.sha256
    }
}

struct AudioFallbackTranscriberConfig: Sendable {
    let binaryURL: URL
    let binaryArtifactID: String
    let binarySHA256: String
    let modelURL: URL?
    let modelArtifactID: String?
    let modelSHA256: String?
    let argumentTemplate: [String]
    let timeoutSeconds: TimeInterval

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        fileHash: (URL) throws -> String = ExternalProcessAudioFallbackTranscriber.sha256Hex(of:),
        lockLoader: (URL) -> AudioFallbackModelsLock? = AudioFallbackModelsLock.load(from:)
    ) -> AudioFallbackTranscriberConfig? {
        guard let binaryPath = environment["FAE_AUDIO_FALLBACK_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !binaryPath.isEmpty
        else {
            return nil
        }
        guard let binaryArtifactID = environment["FAE_AUDIO_FALLBACK_BIN_ARTIFACT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !binaryArtifactID.isEmpty
        else {
            NSLog("AudioFallbackTranscriber: FAE_AUDIO_FALLBACK_BIN set without FAE_AUDIO_FALLBACK_BIN_ARTIFACT_ID; fallback disabled")
            return nil
        }

        guard let lock = lockLoader(modelsLockURL(environment: environment)) else {
            NSLog("AudioFallbackTranscriber: fallback models.lock unavailable; fallback disabled")
            return nil
        }
        guard let expectedBinarySHA = lock.sha256(for: binaryArtifactID) else {
            NSLog("AudioFallbackTranscriber: no lock entry for fallback binary artifact id %@", binaryArtifactID)
            return nil
        }

        let binaryURL = URL(fileURLWithPath: binaryPath)
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            NSLog("AudioFallbackTranscriber: fallback binary is not executable at %@", binaryURL.path)
            return nil
        }
        do {
            let actual = try fileHash(binaryURL)
            guard actual.caseInsensitiveCompare(expectedBinarySHA) == .orderedSame else {
                NSLog("AudioFallbackTranscriber: fallback binary SHA mismatch for %@", binaryURL.path)
                return nil
            }
        } catch {
            NSLog("AudioFallbackTranscriber: could not hash fallback binary %@: %@", binaryURL.path, error.localizedDescription)
            return nil
        }

        let modelURL: URL?
        let modelArtifactID: String?
        let modelSHA: String?
        if let modelPath = environment["FAE_AUDIO_FALLBACK_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelPath.isEmpty
        {
            guard let artifactID = environment["FAE_AUDIO_FALLBACK_MODEL_ARTIFACT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !artifactID.isEmpty
            else {
                NSLog("AudioFallbackTranscriber: FAE_AUDIO_FALLBACK_MODEL set without FAE_AUDIO_FALLBACK_MODEL_ARTIFACT_ID; fallback disabled")
                return nil
            }
            guard let expectedModelSHA = lock.sha256(for: artifactID) else {
                NSLog("AudioFallbackTranscriber: no lock entry for fallback model artifact id %@", artifactID)
                return nil
            }
            let url = URL(fileURLWithPath: modelPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                NSLog("AudioFallbackTranscriber: fallback model is not readable at %@", url.path)
                return nil
            }
            do {
                let actual = try fileHash(url)
                guard actual.caseInsensitiveCompare(expectedModelSHA) == .orderedSame else {
                    NSLog("AudioFallbackTranscriber: fallback model SHA mismatch for %@", url.path)
                    return nil
                }
            } catch {
                NSLog("AudioFallbackTranscriber: could not hash fallback model %@: %@", url.path, error.localizedDescription)
                return nil
            }
            modelURL = url
            modelArtifactID = artifactID
            modelSHA = expectedModelSHA
        } else {
            modelURL = nil
            modelArtifactID = nil
            modelSHA = nil
        }

        let args: [String]
        if let rawArgs = environment["FAE_AUDIO_FALLBACK_ARGS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawArgs.isEmpty
        {
            args = rawArgs.split(separator: " ").map(String.init)
        } else if modelURL != nil {
            // whisper.cpp-compatible default. Qwen3-ASR wrappers should set
            // FAE_AUDIO_FALLBACK_ARGS explicitly.
            args = ["-m", "{model}", "-f", "{wav}", "-nt", "-np"]
        } else {
            // Generic wrapper contract: executable receives the WAV path and
            // prints the transcript to stdout.
            args = ["{wav}"]
        }

        let timeout = TimeInterval(Double(environment["FAE_AUDIO_FALLBACK_TIMEOUT_S"] ?? "30") ?? 30)
        return AudioFallbackTranscriberConfig(
            binaryURL: binaryURL,
            binaryArtifactID: binaryArtifactID,
            binarySHA256: expectedBinarySHA,
            modelURL: modelURL,
            modelArtifactID: modelArtifactID,
            modelSHA256: modelSHA,
            argumentTemplate: args,
            timeoutSeconds: max(1, timeout))
    }

    static func modelsLockURL(environment: [String: String]) -> URL {
        if let path = environment["FAE_AUDIO_FALLBACK_LOCK"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("fae", isDirectory: true)
            .appendingPathComponent("models.lock")
    }
}

struct ExternalProcessAudioFallbackTranscriber: AudioFallbackTranscribing {
    let config: AudioFallbackTranscriberConfig

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExternalProcessAudioFallbackTranscriber? {
        guard let config = AudioFallbackTranscriberConfig.fromEnvironment(environment) else { return nil }
        return ExternalProcessAudioFallbackTranscriber(config: config)
    }

    func transcribe(audioWAVBase64: String) async -> String? {
        guard let data = Data(base64Encoded: audioWAVBase64) else {
            NSLog("AudioFallbackTranscriber: invalid base64 audio")
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-audio-fallback-")
            .appendingPathExtension(UUID().uuidString + ".wav")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            NSLog("AudioFallbackTranscriber: failed to write temp WAV: %@", error.localizedDescription)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = config.binaryURL
        process.arguments = renderedArguments(wavURL: tempURL)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            NSLog("AudioFallbackTranscriber: launch failed: %@", error.localizedDescription)
            return nil
        }

        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                NSLog("AudioFallbackTranscriber: timed out after %.1fs", config.timeoutSeconds)
                return nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            NSLog("AudioFallbackTranscriber: exited %d stderr=%@", process.terminationStatus, err.prefix(300) as NSString)
            return nil
        }
        let transcript = Self.extractTranscript(from: out)
        if transcript.isEmpty {
            NSLog("AudioFallbackTranscriber: empty transcript stdout=%@", out.prefix(300) as NSString)
            return nil
        }
        return transcript
    }

    private func renderedArguments(wavURL: URL) -> [String] {
        config.argumentTemplate.map { arg in
            arg
                .replacingOccurrences(of: "{wav}", with: wavURL.path)
                .replacingOccurrences(of: "{model}", with: config.modelURL?.path ?? "")
        }
    }

    static func extractTranscript(from stdout: String) -> String {
        let lines = stdout
            .split(whereSeparator: \Character.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let line = lines.last else { return "" }
        return DaemonLLMEngine.flattenTranscript(line)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
