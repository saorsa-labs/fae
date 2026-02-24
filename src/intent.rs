//! Centralised keyword constants for intent detection and name matching.
//!
//! Previously these arrays were scattered across `agent/mod.rs` and
//! `pipeline/coordinator.rs`, making it easy for duplicates to drift.
//! Every keyword list referenced by more than one call-site lives here.

// ── Shared helper ───────────────────────────────────────────────────────

/// Returns `true` when **any** of `terms` appears as a substring of `haystack`.
pub(crate) fn contains_any(haystack: &str, terms: &[&str]) -> bool {
    terms.iter().any(|term| haystack.contains(term))
}

// ── Name variants (STT mis-transcriptions of "Fae") ────────────────────

/// All plausible STT transcriptions of "Fae", ordered longest-first so that
/// `find_name_mention` and `canonicalize_wake_word_transcription` prefer the
/// most-specific match.
pub(crate) const FAE_NAME_VARIANTS: &[&str] =
    &["faye", "fae", "fea", "fee", "fay", "fey", "fah", "feh"];

// ── Tool-intent keywords ────────────────────────────────────────────────

pub(crate) const WEB_KEYWORDS: &[&str] = &[
    "search", "look up", "lookup", "latest", "news", "web", "internet", "online", "website",
    "source", "article",
];

pub(crate) const CALENDAR_KEYWORDS: &[&str] =
    &["calendar", "meeting", "event", "schedule on my calendar"];

pub(crate) const REMINDERS_KEYWORDS: &[&str] = &["reminder", "reminders", "todo", "to-do"];

pub(crate) const NOTES_KEYWORDS: &[&str] = &["note", "notes"];

pub(crate) const MAIL_KEYWORDS: &[&str] = &["mail", "email", "inbox"];

pub(crate) const CONTACTS_KEYWORDS: &[&str] =
    &["contact", "contacts", "phone number", "address book"];

pub(crate) const SCHEDULER_KEYWORDS: &[&str] = &[
    "scheduled task",
    "scheduled tasks",
    "automation",
    "automations",
    "remind me every",
    "every day",
    "every week",
];

pub(crate) const BASH_KEYWORDS: &[&str] = &[
    "what time",
    "current time",
    "the time",
    "what date",
    "current date",
    "the date",
    "today's date",
    "what day",
    "disk space",
    "disk usage",
    "how much space",
    "storage",
    "system info",
    "uptime",
    "memory usage",
    "cpu usage",
    "battery",
    "ip address",
    "run a command",
    "run command",
    "run the command",
    "execute",
    "check the weather",
    "what's the weather",
];

pub(crate) const FILE_KEYWORDS: &[&str] = &[
    "read file",
    "open file",
    "show file",
    "in this file",
    "in this repo",
    "in this project",
];

pub(crate) const X0X_KEYWORDS: &[&str] = &[
    "x0x",
    "network",
    "gossip",
    "peer",
    "peers",
    "mesh",
    "swarm",
    "publish",
    "subscribe",
    "presence",
    "agents online",
    "other agents",
    "find agent",
    "task list",
    "collaborative",
];

// ── Reasoning-depth keywords ────────────────────────────────────────────

pub(crate) const DEEPER_REASONING_KEYWORDS: &[&str] = &[
    "explain",
    "analyze",
    "analyse",
    "compare",
    "contrast",
    "pros and cons",
    "advantages and disadvantages",
    "trade-off",
    "tradeoff",
    "think about",
    "think through",
    "reason about",
    "help me understand",
    "break down",
    "walk me through",
    "step by step",
    "why does",
    "why would",
    "why is it",
    "how does",
    "how would",
    "what if",
    "what would happen",
    "implications of",
    "consequences of",
    "difference between",
    "summarize",
    "summarise",
    "evaluate",
    "assessment",
    "critique",
    "recommend",
    "should i",
    "plan for",
    "strategy for",
    "design a",
    "architect",
];

/// Subset of `BASH_KEYWORDS` that identify pure system-utility questions
/// (date, time, disk, etc.) which need no internal reasoning at all.
pub(crate) const BRIEF_REASONING_KEYWORDS: &[&str] = &[
    "what time",
    "current time",
    "the time",
    "what date",
    "current date",
    "today's date",
    "what day",
    "uptime",
    "disk space",
    "disk usage",
    "storage",
    "memory usage",
    "cpu usage",
    "battery",
    "ip address",
];

// ── Coding-context keywords ─────────────────────────────────────────────

/// Keywords that indicate the user is asking about code / development —
/// used to decide whether to inject local coding-assistant context into
/// the prompt.
///
/// Note: `"implementation"` alone is intentionally excluded (too broad,
/// triggers on non-coding queries like "explain the implementation of
/// democracy"). `"implement this"` is kept as it signals a coding task.
pub(crate) const CODING_CONTEXT_KEYWORDS: &[&str] = &[
    "code",
    "coding",
    "bug",
    "debug",
    "refactor",
    "compile",
    "build failed",
    "test failure",
    "unit test",
    "cargo",
    "rust",
    "python",
    "typescript",
    "javascript",
    "repo",
    "repository",
    "pull request",
    "commit",
    "stack trace",
    "implement this",
    "patch",
    "codex",
    "claude code",
];
