import Foundation

/// Temporary, task-scoped capability grant consumed by policy broker.
struct CapabilityTicket: Sendable {
    let id: String
    let issuedAt: Date
    let expiresAt: Date
    let allowedTools: Set<String>

    /// Optional script run ID binding this ticket to a specific JSC execution.
    /// When set, the ticket is only valid for that run and is revoked when
    /// the run completes, fails, or is cancelled.
    let scriptRunId: String?

    init(
        id: String,
        issuedAt: Date,
        expiresAt: Date,
        allowedTools: Set<String>,
        scriptRunId: String? = nil
    ) {
        self.id = id
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.allowedTools = allowedTools
        self.scriptRunId = scriptRunId
    }

    /// Whether this ticket grants access to a specific tool right now.
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

    /// Issue a script-scoped ticket bound to a specific JSC run.
    ///
    /// The ticket is only valid for the given `scriptRunId` and expires at
    /// either the TTL deadline or when the script run completes, whichever
    /// comes first.
    static func issueForScript(
        scriptRunId: String,
        allowedTools: Set<String>,
        ttlSeconds: TimeInterval = 300
    ) -> CapabilityTicket {
        let now = Date()
        return CapabilityTicket(
            id: UUID().uuidString,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds),
            allowedTools: allowedTools,
            scriptRunId: scriptRunId
        )
    }
}

/// Manages the lifecycle of script-scoped capability tickets.
///
/// Tickets are issued when a JSC script run starts and automatically revoked
/// when the run completes, fails, or is cancelled. This prevents ticket reuse
/// across separate script executions or LLM turns.
///
/// Thread-safe: all mutations go through a serial dispatch queue.
final class ScriptScopedTicketManager: @unchecked Sendable {

    /// Serial queue protecting mutable ticket state.
    private let queue = DispatchQueue(label: "fae.capability.ticket.manager")

    /// Active tickets keyed by script run ID.
    private var activeTickets: [String: CapabilityTicket] = [:]

    /// Issue a new script-scoped ticket for the given run.
    ///
    /// - Parameters:
    ///   - scriptRunId: Unique identifier for the script execution.
    ///   - allowedTools: The set of tools this ticket grants access to.
    ///   - ttlSeconds: Time-to-live for the ticket. Defaults to 300s.
    /// - Returns: The issued ticket, or `nil` if a ticket already exists for this run.
    func issue(
        scriptRunId: String,
        allowedTools: Set<String>,
        ttlSeconds: TimeInterval = 300
    ) -> CapabilityTicket? {
        queue.sync {
            guard activeTickets[scriptRunId] == nil else {
                return nil
            }
            let ticket = CapabilityTicketIssuer.issueForScript(
                scriptRunId: scriptRunId,
                allowedTools: allowedTools,
                ttlSeconds: ttlSeconds
            )
            activeTickets[scriptRunId] = ticket
            return ticket
        }
    }

    /// Revoke the ticket for a completed, failed, or cancelled script run.
    ///
    /// - Parameter scriptRunId: The script run whose ticket should be revoked.
    /// - Returns: The revoked ticket, or `nil` if no active ticket existed.
    @discardableResult
    func revoke(scriptRunId: String) -> CapabilityTicket? {
        queue.sync {
            activeTickets.removeValue(forKey: scriptRunId)
        }
    }

    /// Look up the active ticket for a script run.
    ///
    /// - Parameter scriptRunId: The script run to look up.
    /// - Returns: The active ticket, or `nil` if none exists or it has expired.
    func ticket(for scriptRunId: String) -> CapabilityTicket? {
        queue.sync {
            guard let ticket = activeTickets[scriptRunId] else { return nil }
            // Auto-expire: if the ticket's TTL has passed, remove and return nil.
            if Date() > ticket.expiresAt {
                activeTickets.removeValue(forKey: scriptRunId)
                return nil
            }
            return ticket
        }
    }

    /// Whether a specific tool is allowed under the ticket for a script run.
    ///
    /// Returns `false` if no ticket exists, the ticket has expired, or the
    /// tool is not in the allowed set.
    func allows(toolName: String, scriptRunId: String) -> Bool {
        guard let ticket = ticket(for: scriptRunId) else { return false }
        return ticket.allows(toolName: toolName)
    }

    /// The number of currently active (non-expired) tickets.
    var activeCount: Int {
        queue.sync {
            // Prune expired tickets during count.
            let now = Date()
            activeTickets = activeTickets.filter { $0.value.expiresAt >= now }
            return activeTickets.count
        }
    }

    /// Remove all active tickets. Used during shutdown or rescue mode.
    func revokeAll() {
        queue.sync {
            activeTickets.removeAll()
        }
    }
}
