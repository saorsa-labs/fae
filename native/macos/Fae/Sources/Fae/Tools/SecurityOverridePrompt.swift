import Foundation

/// The hardware-click-only authorize card's resolver (security-override Wave 2,
/// L2 / L6 / L12).
///
/// This is a **one-shot** resolver, modelled on `ToolHostOperationWaiter`: exactly
/// one of {a button click, the 10 s timeout} wins and resolves the awaited
/// `result()`; every later signal is a no-op. It is deliberately UI-independent so
/// the security-critical semantics (one-shot resolve, timeout = Deny, late click
/// no-op, tier → allowed buttons) are hermetically testable WITHOUT AppKit. The
/// AppKit panel (`SecurityOverridePanel`) constructs one of these, awaits
/// `result()`, and wires its buttons ONLY to `approve(_:)` / `deny()`.
///
/// INVARIANT H (human-only): the ONLY producers of an `.allow` decision are
/// `approve(_:)` (called from a real hardware button click) and — for a
/// previously-authorized stored grant — `GrantStore` auto-apply on an interactive
/// turn. No legacy approval route (`VoiceCommandParser`, TestServer `/approve`,
/// `respondToApproval()`) can reach this type; the override directive is minted
/// only downstream of an `.allow` decision.
final class SecurityOverridePrompt: @unchecked Sendable {
    /// The denial being authorized (drives the shown tier + target).
    let denial: SecurityDenial
    /// The FULL, unelided command the user is authorizing (shown verbatim, L12).
    let command: String
    /// Timeout before the card auto-denies (default 10 s; injectable for tests).
    let timeoutSeconds: Double

    private let lock = NSLock()
    private var continuation: CheckedContinuation<SecurityOverrideDecision, Never>?
    private var resolved = false
    /// A decision that arrived BEFORE `result()` armed the continuation (closes the
    /// resolve-before-await race, mirroring `ToolHostOperationWaiter`).
    private var pending: SecurityOverrideDecision?

    init(denial: SecurityDenial, command: String, timeoutSeconds: Double = 10) {
        self.denial = denial
        self.command = command
        self.timeoutSeconds = timeoutSeconds
    }

    /// The authorize buttons offered for a tier (Part B), in display order:
    /// - General → Allow once, Always allow (persistent)
    /// - Secrets → Allow once, Allow 5 min (expiring) — NO "always"
    /// - Fae-integrity → NONE (Deny only; never overridable)
    static func allowedGrantKinds(for tier: SecurityTier) -> [SecurityGrantKind] {
        switch tier {
        case .general: return [.once, .persistent]
        case .secrets: return [.once, .expiring]
        case .faeIntegrity: return []
        }
    }

    /// The allowed grant kinds for THIS prompt's denial tier.
    var allowedGrantKinds: [SecurityGrantKind] {
        Self.allowedGrantKinds(for: denial.tier)
    }

    /// The plain-language L12 consent body: names the sandbox exit unmistakably,
    /// shows the FULL command verbatim, and names the tier. Default is always Deny.
    var consentText: String {
        let display = SecurityDenial.tildeCollapsed(denial.target)
        var lines: [String] = []
        lines.append(
            "You're about to let me step OUTSIDE my safety sandbox and read/act on "
            + "\(display) directly on your computer.")
        lines.append("")
        lines.append("Tier: \(denial.tier.displayName)")
        lines.append("Full command:")
        lines.append(command)
        if denial.tier == .faeIntegrity {
            lines.append("")
            lines.append(
                "This is one of my own trust anchors. It is NEVER overridable — "
                + "there is no way to allow it.")
        }
        return lines.joined(separator: "\n")
    }

    /// Await the human's decision. Starts the timeout on first call; the returned
    /// decision is whatever resolved FIRST (a click or the timeout → Deny).
    func result() async -> SecurityOverrideDecision {
        // Arm the timeout. A cancelled task (card dismissed) also resolves Deny.
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
            _ = self.resolve(.deny)
        }
        let decision: SecurityOverrideDecision = await withCheckedContinuation { cont in
            lock.lock()
            if let pending {
                // A button/timeout already fired before we armed — honor it.
                lock.unlock()
                cont.resume(returning: pending)
                return
            }
            if resolved {
                lock.unlock()
                cont.resume(returning: .deny)
                return
            }
            continuation = cont
            lock.unlock()
        }
        timeoutTask.cancel()
        return decision
    }

    /// Authorize with a grant kind — the ONLY human-click entry point. Ignored
    /// (returns `false`) if the kind is not offered for the tier (defence against
    /// a UI wiring bug offering "always" for Secrets) or the card already resolved.
    @discardableResult
    func approve(_ kind: SecurityGrantKind) -> Bool {
        guard allowedGrantKinds.contains(kind) else { return false }
        return resolve(.allow(kind))
    }

    /// Explicitly deny (the default action / Deny button).
    @discardableResult
    func deny() -> Bool {
        resolve(.deny)
    }

    /// One-shot resolve. Returns `true` iff THIS call is the one that resolved the
    /// card; a late click after the timeout (or a second click) returns `false`
    /// and does nothing (L6).
    @discardableResult
    private func resolve(_ decision: SecurityOverrideDecision) -> Bool {
        lock.lock()
        if resolved {
            lock.unlock()
            return false
        }
        resolved = true
        let cont = continuation
        continuation = nil
        if cont == nil {
            // Nobody is awaiting yet — stash for result()'s arm step.
            pending = decision
        }
        lock.unlock()
        cont?.resume(returning: decision)
        return true
    }
}
