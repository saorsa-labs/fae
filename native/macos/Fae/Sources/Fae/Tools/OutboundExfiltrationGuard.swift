import CryptoKit
import Foundation

actor OutboundExfiltrationGuard {
    static let shared = OutboundExfiltrationGuard()

    enum GuardDecision {
        case confirm(message: String)
        case deny(message: String)

        var reasonCode: DecisionReasonCode {
            switch self {
            case .confirm:
                return .outboundRecipientNovelty
            case .deny:
                return .outboundPayloadRisk
            }
        }
    }

    private struct State: Codable {
        var knownRecipientHashes: Set<String> = []
    }

    private var state: State = .init()
    private var loaded = false

    private var stateURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/security/outbound-recipients.json")
    }

    func evaluate(toolName: String, arguments: [String: Any]) -> GuardDecision? {
        guard isOutboundTool(toolName) else { return nil }
        loadIfNeeded()

        let recipient = extractRecipient(from: arguments)
        let payload = extractPayload(from: arguments)

        if let payload, payloadLooksSensitive(payload) {
            return .deny(message: "This outgoing message may contain sensitive data. I blocked it for safety.")
        }

        if let recipient {
            let hash = recipientHash(recipient)
            if !state.knownRecipientHashes.contains(hash) {
                return .confirm(message: "This is a new recipient. Confirm before sending.")
            }
        }

        return nil
    }

    func recordSuccessfulSend(toolName: String, arguments: [String: Any]) {
        guard isOutboundTool(toolName) else { return }
        guard let recipient = extractRecipient(from: arguments) else { return }

        loadIfNeeded()
        let hash = recipientHash(recipient)
        guard !state.knownRecipientHashes.contains(hash) else { return }

        state.knownRecipientHashes.insert(hash)
        saveState()
    }

    private func isOutboundTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("send")
            || normalized.contains("post")
            || normalized.contains("publish")
            || normalized.contains("mail_out")
            || normalized.contains("channel_out")
    }

    private func extractRecipient(from args: [String: Any]) -> String? {
        let keys = ["recipient", "to", "email", "phone", "target", "channel", "channel_id"]
        for key in keys {
            if let value = args[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        return nil
    }

    private func extractPayload(from args: [String: Any]) -> String? {
        let keys = ["body", "message", "content", "text", "payload"]
        for key in keys {
            if let value = args[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private func payloadLooksSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = [
            "password", "passphrase", "secret", "api_key", "apikey", "token",
            "private key", "ssh-rsa", "-----begin", "credential",
        ]
        if keywords.contains(where: { lower.contains($0) }) {
            return true
        }

        // Cheap entropy heuristic: long base64/hex-like chunks.
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9+/=_-]{40,}") {
            let nsRange = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: nsRange) != nil {
                return true
            }
        }
        return false
    }

    private func recipientHash(_ recipient: String) -> String {
        let digest = SHA256.hash(data: Data(recipient.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(State.self, from: data)
        else {
            return
        }
        state = decoded
    }

    #if DEBUG
    func resetForTesting() {
        state = .init()
        loaded = true
        try? FileManager.default.removeItem(at: stateURL)
    }
    #endif

    private func saveState() {
        do {
            let dir = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("OutboundExfiltrationGuard: failed to save state: %@", error.localizedDescription)
        }
    }
}
