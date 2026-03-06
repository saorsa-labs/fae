import Foundation

/// Temporary, task-scoped capability grant consumed by policy broker.
struct CapabilityTicket: Sendable {
    let id: String
    let issuedAt: Date
    let expiresAt: Date
    let allowedTools: Set<String>

    func allows(toolName: String, now: Date = Date()) -> Bool {
        now <= expiresAt && allowedTools.contains(toolName)
    }
}

enum CapabilityTicketIssuer {
    /// Issue a conservative capability ticket for the current turn.
    ///
    /// Scope is bounded by the active tool mode and expires automatically.
    static func issue(
        mode: String,
        privacyMode: String = "local_preferred",
        registry: ToolRegistry,
        ttlSeconds: TimeInterval = 300
    ) -> CapabilityTicket {
        let now = Date()
        let allowed = Set(
            registry.toolNames.filter { registry.isToolAllowed($0, mode: mode, privacyMode: privacyMode) }
        )

        return CapabilityTicket(
            id: UUID().uuidString,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds),
            allowedTools: allowed
        )
    }
}
