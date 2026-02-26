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
    "article",
];

pub(crate) const CALENDAR_KEYWORDS: &[&str] = &[
    "calendar",
    "meeting",
    "event",
    "schedule on my calendar",
    "what's on my schedule",
    "when is my",
    "book a meeting",
    "block time",
];

pub(crate) const REMINDERS_KEYWORDS: &[&str] = &[
    "reminder",
    "reminders",
    "todo",
    "to-do",
    "remind me",
    "set a reminder",
    "add a reminder",
    "don't forget",
];

pub(crate) const NOTES_KEYWORDS: &[&str] = &[
    "my notes",
    "in notes",
    "apple notes",
    "create a note",
    "save a note",
    "notes app",
];

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
    "recurring",
    "run every",
    "schedule a task",
    "set up automation",
    "daily task",
    // Natural queries users actually say:
    "show schedules",
    "show my schedule",
    "list schedules",
    "my schedules",
    "my scheduled",
    "what tasks",
    "show tasks",
    "list tasks",
    "my tasks",
    "fae's tasks",
    "set a schedule",
    "create a schedule",
    "add a schedule",
    "morning briefing",
    "daily briefing",
    "briefing",
    // Natural spoken phrases:
    "each morning",
    "every morning",
    "each evening",
    "every evening",
    "each night",
    "every night",
    "morning report",
    "morning update",
    "daily report",
    "daily update",
    "each day",
    "tell me daily",
    "tell me each",
    "tell me every",
    "want to know each",
    "want to know every",
    "set me up",
    "set up a morning",
    "set up a daily",
    "set up a weekly",
    "let me know each",
    "let me know every",
    "notify me each",
    "notify me every",
    "check for me each",
    "check for me every",
    "schedule for me",
    "set up for me",
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
    "x0x network",
    "gossip network",
    "peer network",
    "peers",
    "mesh",
    "swarm",
    "publish to x0x",
    "publish message",
    "subscribe",
    "presence",
    "agents online",
    "other agents",
    "find agent",
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
    "git commit",
    "stack trace",
    "implement this",
    "apply patch",
    "patch file",
    "codex",
    "claude code",
];

// ── Desktop & canvas keywords ─────────────────────────────────────────

/// Keywords indicating desktop automation intent — screenshots, window
/// management, mouse/keyboard simulation.
pub(crate) const DESKTOP_KEYWORDS: &[&str] = &[
    "screenshot",
    "take a screenshot",
    "click on",
    "type into",
    "list windows",
    "focus window",
    "launch app",
];

/// Keywords indicating canvas/visualization intent.
pub(crate) const CANVAS_KEYWORDS: &[&str] =
    &["draw", "chart", "graph", "diagram", "visualize", "render a"];

/// Short affirmative phrases used to confirm a previously proposed action.
///
/// Used by `classify_intent_with_context` to detect when the user is approving
/// something Fae offered to do in the prior turn (e.g. "yes, go ahead" after
/// Fae said "I'll set up a daily briefing for you").
pub(crate) const CONFIRMATION_KEYWORDS: &[&str] = &[
    "yes",
    "yeah",
    "yep",
    "yup",
    "sure",
    "ok",
    "okay",
    "go ahead",
    "please do",
    "do it",
    "sounds good",
    "alright",
    "of course",
    "absolutely",
    "definitely",
    "please",
    "go for it",
    "make it so",
    "proceed",
    "confirm",
    "perfect",
    "great",
];
