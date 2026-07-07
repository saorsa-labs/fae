import Foundation

/// The truthful per-turn origin Swift stamps on every `toolhost.execute` payload
/// (security-override Wave 2, L1 — also closes gap #38).
///
/// The daemon maps `owner_interactive` → the Host tier (may run un-jailed) and
/// every other origin → the OS jail (Jailed tier). Critically, the daemon's
/// human-gated `security_override` gate REFUSES any override unless the request's
/// origin is `owner_interactive`. So a proactive / scheduler / auto-skill /
/// script-block bash MUST carry its real, non-interactive origin — never
/// `owner_interactive` — so the daemon jails it and refuses to relax the sandbox
/// on its behalf.
///
/// The raw values are the EXACT wire strings the daemon's `parse_tool_origin`
/// accepts (`crates/fae-daemon/src/session.rs`); a mismatch is a hard daemon-side
/// `unknown origin` error, so these must stay in lockstep.
enum DaemonToolOrigin: String, Sendable, Equatable, CaseIterable {
    /// A genuine interactive owner turn (voice/text tool-call). The ONLY origin
    /// under which the daemon will honor a human-gated `security_override`.
    case ownerInteractive = "owner_interactive"
    /// A proactive/awareness turn injected by the scheduler's proactive lane.
    case proactive = "proactive"
    /// A scheduler task turn.
    case scheduler = "scheduler"
    /// An autonomously-run skill turn.
    case autoSkill = "auto_skill"
    /// A `<tool_program>` JavaScript block executed via JSCRuntime.
    case scriptBlock = "script_block"
    /// A delegated sub-agent loop turn.
    case delegated = "delegated"

    /// Whether this is a genuine interactive owner turn. Only an interactive
    /// origin may drive a human-gated sandbox override (L1/L9): there is no human
    /// present on an autonomous turn to click the authorize card.
    var isInteractive: Bool { self == .ownerInteractive }
}
