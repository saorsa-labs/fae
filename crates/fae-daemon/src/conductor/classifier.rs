//! M4 — content-aware task classifier (the designated F-4/n boundary-crossing surface).
//!
//! This is the **one** component in the conductor that reads prompt text. Everything
//! else stays content-blind: [`crate::conductor::policy::StaticDirectPolicy`] consumes
//! the *label* this module emits, never the prompt. The classifier runs **local-only**,
//! is **synchronous, pure, and infallible** (any failure path fails closed to
//! `Unknown + []`), and emits **labels only** — a [`ConductorTaskClass`] enum variant,
//! an allowlisted [`Vec<String>`] of predicate names, and a [`ClassifierSource`] tag.
//! It never returns the prompt text, a prompt hash, or a prompt fingerprint.
//!
//! ## Why this exists
//!
//! M2's routing-accuracy reward is **degenerate**: the live [`ConductorTurnContext`] is
//! built content-blind (`task_class = Unknown`, `feature_predicates = []`), so
//! [`crate::conductor::shadow::match_corpus_entry`] — which requires
//! `entry.feature_predicates ⊆ ctx.feature_predicates` — matches zero corpus entries
//! ⇒ `corpus_match = None` for every turn. The classifier populates those fields so
//! routing accuracy becomes measurable. It is the hard gate for any live mutation loop
//! (owner directive 2026-06-25; execution-plan Sequencing).
//!
//! ## MVP scope
//!
//! [`RuleBasedTurnClassifier`] is a deterministic rule-based classifier — no `fae-engine`,
//! no mistralrs, no async, no network. The [`TurnClassifier`] trait is the upgrade
//! surface for a future local-LLM impl (additive, same trait, same F-4 contract).
//!
//! ## Safety posture (why obfuscation-resistance is lower-stakes here)
//!
//! A classifier *miss* (failing to detect `credential_shaped`/`personal_data_shaped`)
//! does NOT cause egress today: [`crate::conductor::policy::StaticDirectPolicy`] is
//! M1-inert to `task_class` (always `direct` + `local-model`), so the label only
//! affects shadow/corpus *measurement*, not the route. Obfuscation-resistance here is a
//! measurement-quality concern, not a safety bypass. (Contrast with the prompt lint,
//! where obfuscation IS a safety bypass — that's why the lint does full NFKC + zero-width
//! stripping and this classifier does plain `to_ascii_lowercase()` keyword matching.)
//! Spec: `docs/architecture/conductor-m4-content-aware-classifier-spec-2026-06-27.md`.

use crate::conductor::recipe::ConductorTaskClass;

/// Long-prompt length threshold (chars). Matches the recipe.rs `len>2000` example.
const LONG_PROMPT_THRESHOLD: usize = 2_000;

/// A stable, allowlisted feature-predicate name emitted by the classifier.
///
/// Fixed vocabulary — aligned to the eval corpus so
/// [`crate::conductor::shadow::match_corpus_entry`] can hit. `as_str()` is the
/// serialized/compared form; the classifier **never** emits free-form strings. The eval
/// corpus fixture spellings are migrated to these canonical names (M4-A).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FeaturePredicate {
    /// Fenced (``` ``` ```) code block present.
    HasCodeblock,
    /// Inline `` `code` `` span present.
    HasInlineCode,
    /// Path-shaped token (`/path`, `~/`, `./rel`, `name.ext`).
    HasFilePath,
    /// Imperative tool/commands ("run", "execute", "install", "build", …).
    ToolRequest,
    /// Planning / decomposition / step language.
    PlanningShaped,
    /// Research / search / cite language.
    ResearchShaped,
    /// First-person personal content (health, finance, relationships).
    PersonalDataShaped,
    /// Secret / key / token patterns.
    CredentialShaped,
    /// Prompt length above [`LONG_PROMPT_THRESHOLD`].
    LongPrompt,
}

impl FeaturePredicate {
    /// The canonical serialized form. This is the exact string both the classifier
    /// emits and corpus entries must carry for a subset match.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            FeaturePredicate::HasCodeblock => "has_codeblock",
            FeaturePredicate::HasInlineCode => "has_inline_code",
            FeaturePredicate::HasFilePath => "has_file_path",
            FeaturePredicate::ToolRequest => "tool_request",
            FeaturePredicate::PlanningShaped => "planning_shaped",
            FeaturePredicate::ResearchShaped => "research_shaped",
            FeaturePredicate::PersonalDataShaped => "personal_data_shaped",
            FeaturePredicate::CredentialShaped => "credential_shaped",
            FeaturePredicate::LongPrompt => "long_prompt",
        }
    }

    /// All variants, in canonical (as_str alphabetical) order — the order emitted in
    /// [`TurnClassification::feature_predicates`].
    const ALL: [FeaturePredicate; 9] = [
        FeaturePredicate::CredentialShaped,
        FeaturePredicate::HasCodeblock,
        FeaturePredicate::HasFilePath,
        FeaturePredicate::HasInlineCode,
        FeaturePredicate::LongPrompt,
        FeaturePredicate::PersonalDataShaped,
        FeaturePredicate::PlanningShaped,
        FeaturePredicate::ResearchShaped,
        FeaturePredicate::ToolRequest,
    ];
}

/// Which classifier produced a [`TurnClassification`]. Rides on shadow telemetry only —
/// NOT added to [`crate::conductor::recipe::ConductorTurnContext`] (M4 keeps the live
/// context's field set unchanged).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClassifierSource {
    /// [`RuleBasedTurnClassifier`], vocabulary v1.
    RuleBasedV1,
}

impl ClassifierSource {
    /// Canonical serialized form. Intended for shadow telemetry (which classifier
    /// produced a record) — NOT yet wired this slice (deferred to avoid an
    /// event/receipt schema change); the live context carries no source field.
    #[allow(dead_code)] // TODO(follow-up): attach to ShadowTurnRecord telemetry
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            ClassifierSource::RuleBasedV1 => "rule-based-v1",
        }
    }
}

/// The output of classifying a turn. **Labels only** — never prompt content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnClassification {
    pub task_class: ConductorTaskClass,
    /// Sorted (canonical order), deduped, every element a known
    /// [`FeaturePredicate::as_str()`].
    pub feature_predicates: Vec<String>,
    pub source: ClassifierSource,
}

impl TurnClassification {
    /// The fail-closed classification: no information derived. Used when the prompt is
    /// empty, non-text, or the classifier is disabled. Never panics, never `Err`.
    #[must_use]
    fn fail_closed(source: ClassifierSource) -> TurnClassification {
        TurnClassification {
            task_class: ConductorTaskClass::Unknown,
            feature_predicates: Vec::new(),
            source,
        }
    }
}

/// Classify a turn's prompt text. The **one** designated F-4/n content-reader.
///
/// Pure + infallible by construction: implementations MUST NOT panic, MUST NOT return
/// `Err`, and MUST fail closed to [`TurnClassification::fail_closed`] on any
/// unclassifiable input. Synchronous + local-only — no I/O, no network, no model load.
pub trait TurnClassifier: Send + Sync {
    fn classify(&self, prompt: &str) -> TurnClassification;
}

/// Deterministic rule-based classifier (MVP). No model, no async, no I/O, no cloud.
///
/// Constructed via [`RuleBasedTurnClassifier::default`]; held for the process or built
/// per-turn (it is a zero-field unit struct — no allocation cost).
#[derive(Debug, Clone, Default)]
pub struct RuleBasedTurnClassifier;

impl TurnClassifier for RuleBasedTurnClassifier {
    fn classify(&self, prompt: &str) -> TurnClassification {
        // Empty / whitespace-only ⇒ fail closed. (A real greeting like "hi" classifies
        // to Chat below; only truly empty input is Unknown.)
        if prompt.trim().is_empty() {
            return TurnClassification::fail_closed(ClassifierSource::RuleBasedV1);
        }
        // Collect the fired predicates, then derive task_class by precedence.
        let fired = detect_predicates(prompt);
        let task_class = derive_task_class(prompt, &fired);
        // Emit sorted (canonical order) + deduped predicate strings. Iterating ALL in
        // canonical order + membership-testing fired gives both properties for free.
        let feature_predicates = FeaturePredicate::ALL
            .iter()
            .copied()
            .filter(|p| fired.contains(p))
            .map(FeaturePredicate::as_str)
            .map(str::to_owned)
            .collect();
        TurnClassification {
            task_class,
            feature_predicates,
            source: ClassifierSource::RuleBasedV1,
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Detection rules — pure functions over the prompt string. Conservative by design:
// false-negatives are safe (fail toward Unknown/Chat, which is the local default);
// false-positives only skew shadow measurement, never egress.
// ════════════════════════════════════════════════════════════════════════════

/// Detect all fired predicates. Each detector is a small pure function.
fn detect_predicates(prompt: &str) -> Vec<FeaturePredicate> {
    let lower = prompt.to_ascii_lowercase();
    let mut out = Vec::new();
    if has_codeblock(prompt) {
        out.push(FeaturePredicate::HasCodeblock);
    }
    if has_inline_code(prompt) {
        out.push(FeaturePredicate::HasInlineCode);
    }
    if has_file_path(&lower) {
        out.push(FeaturePredicate::HasFilePath);
    }
    if is_tool_request(&lower) {
        out.push(FeaturePredicate::ToolRequest);
    }
    if is_planning_shaped(&lower) {
        out.push(FeaturePredicate::PlanningShaped);
    }
    if is_research_shaped(&lower) {
        out.push(FeaturePredicate::ResearchShaped);
    }
    if is_personal_data_shaped(&lower) {
        out.push(FeaturePredicate::PersonalDataShaped);
    }
    if is_credential_shaped(&lower, prompt) {
        out.push(FeaturePredicate::CredentialShaped);
    }
    if prompt.chars().count() >= LONG_PROMPT_THRESHOLD {
        out.push(FeaturePredicate::LongPrompt);
    }
    out
}

/// Derive the task class from the fired predicates. Precedence is privacy-first:
/// credential/personal-data signals win (route local-only), then code, then tool,
/// then planning/research, else Chat. Empty input is handled by the caller (Unknown).
fn derive_task_class(prompt: &str, fired: &[FeaturePredicate]) -> ConductorTaskClass {
    let has = |p: FeaturePredicate| fired.contains(&p);
    if has(FeaturePredicate::CredentialShaped) || has(FeaturePredicate::PersonalDataShaped) {
        ConductorTaskClass::PersonalData
    } else if has(FeaturePredicate::HasCodeblock) || has(FeaturePredicate::HasInlineCode) {
        ConductorTaskClass::Coding
    } else if has(FeaturePredicate::ToolRequest) {
        ConductorTaskClass::ToolUse
    } else if has(FeaturePredicate::PlanningShaped) {
        ConductorTaskClass::Planning
    } else if has(FeaturePredicate::ResearchShaped) {
        ConductorTaskClass::Research
    } else {
        // Anything non-empty with no fired signal is a plain chat turn.
        let _ = prompt;
        ConductorTaskClass::Chat
    }
}

/// Fenced code block: a line starting with ``` (the common case). Detects ``` on its
/// own line or leading the prompt.
fn has_codeblock(prompt: &str) -> bool {
    prompt
        .split('\n')
        .any(|line| line.trim_start().starts_with("```"))
}

/// Inline code: a backtick-wrapped span that is NOT a fence. A fence line (``````)
/// would also match a naive backtick-pair check, so exclude fence lines first.
fn has_inline_code(prompt: &str) -> bool {
    for line in prompt.split('\n') {
        if line.trim_start().starts_with("```") {
            continue; // fence line — handled by has_codeblock.
        }
        if has_backtick_pair(line) {
            return true;
        }
    }
    false
}

/// True iff `line` contains a `` `…` `` pair with non-empty inner content.
fn has_backtick_pair(line: &str) -> bool {
    let mut in_span = false;
    let mut span_len = 0usize;
    for ch in line.chars() {
        if ch == '`' {
            if !in_span {
                in_span = true;
                span_len = 0;
            } else if span_len > 0 {
                return true; // closing backtick of a non-empty span
            } // else: empty `` — keep scanning (treat as not-a-span)
        } else if in_span {
            span_len += 1;
        }
    }
    false
}

/// Path-shaped token: a `/`-joined path, a home/relative prefix, or a `name.<ext>`
/// for a known code extension. Conservative — requires structure, not just a dot.
fn has_file_path(lower: &str) -> bool {
    // Absolute-ish or nested path with a slash between word chars.
    if lower
        .split_whitespace()
        .any(|tok| tok.contains('/') && tok.chars().any(|c| c.is_alphanumeric()) && tok.len() > 1)
    {
        return true;
    }
    // Home / relative prefix.
    if lower.contains("~/") || lower.contains("./") {
        return true;
    }
    // Known code-file extension on a bare filename.
    const EXTS: &[&str] = &[
        ".rs", ".py", ".sh", ".toml", ".json", ".yaml", ".yml", ".js", ".ts", ".go", ".md",
    ];
    lower
        .split_whitespace()
        .any(|tok| EXTS.iter().any(|ext| tok.ends_with(ext)))
}

/// Imperative tool request. Matches a bounded set of command verbs at word boundaries,
/// to avoid free-text false positives ("I want to run an idea by you" must NOT fire —
/// hence "run an idea" is excluded by requiring a command-shaped follower is NOT tried
/// here; instead we require the verb immediately followed by a token that looks like a
/// command/file, OR a known imperative phrase). Conservative: specific phrases only.
fn is_tool_request(lower: &str) -> bool {
    // Imperative verb + command-shaped follower (run/build/test/install/deploy <X>).
    // Match on WORD BOUNDARIES (split into words), not raw substrings: a bare
    // `find("test ")` would match inside "latest "/"contest "/"installment ",
    // firing on natural language. The verb must be a standalone word followed by
    // a command-shaped token (one with structural punctuation: `.`/`/`/`-`/`_`).
    const VERBS: &[&str] = &["run", "build", "test", "install", "deploy", "execute"];
    let words: Vec<&str> = lower.split_whitespace().collect();
    for (i, w) in words.iter().enumerate() {
        if VERBS.contains(&trim_word(w)) {
            if let Some(next) = words.get(i + 1) {
                let follower = trim_command_word(next);
                if !follower.is_empty() && is_command_shaped(follower) {
                    return true;
                }
            }
        }
    }
    // Direct shell-imperative phrasing (multi-word phrases are substring-safe).
    lower.contains("execute the command")
        || lower.contains("run this command")
        || lower.contains("in the terminal")
        || lower.contains("run the script")
}

/// Strip trailing non-alphanumeric punctuation from a word (for verb matching):
/// "run," / "test:" still match "run" / "test".
fn trim_word(w: &str) -> &str {
    w.trim_end_matches(|c: char| !c.is_alphanumeric())
}

/// For a command-follower word, keep command punctuation (`.`/`/`/`-`/`_`) but
/// strip other trailing punctuation (commas, etc.).
fn trim_command_word(w: &str) -> &str {
    w.trim_end_matches(|c: char| !(c.is_alphanumeric() || matches!(c, '.' | '/' | '-' | '_')))
}

/// A token that plausibly names a command, binary, or file. Requires a structural
/// punctuation mark (`.`/`/`/`-`/`_`) so natural-language followers ("an", "the",
/// "this") don't qualify. "build.sh", "deploy-app", "app.py" do.
fn is_command_shaped(tok: &str) -> bool {
    !tok.is_empty()
        && tok
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'))
        && tok.chars().any(|c| c.is_alphanumeric())
        && tok.chars().any(|c| matches!(c, '.' | '/' | '-' | '_'))
}

fn is_planning_shaped(lower: &str) -> bool {
    const MARKERS: &[&str] = &[
        "plan",
        "steps",
        "step 1",
        "break down",
        "break this down",
        "roadmap",
        "strategy",
        "approach",
        "outline",
        "milestone",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

fn is_research_shaped(lower: &str) -> bool {
    const MARKERS: &[&str] = &[
        "research",
        "search for",
        "look up",
        "find out",
        "cite",
        "sources",
        "what does the literature",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

fn is_personal_data_shaped(lower: &str) -> bool {
    // First-person personal content: health, finance, relationships. Conservative
    // phrase matches (not single words — avoids false positives).
    const MARKERS: &[&str] = &[
        "my health",
        "my doctor",
        "my diagnosis",
        "my medication",
        "my bank",
        "my account",
        "my salary",
        "my partner",
        "my family",
        "my relationship",
        "i feel",
        "i'm feeling",
        "my therapist",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

fn is_credential_shaped(lower: &str, original: &str) -> bool {
    // Secret-bearing words/phrases — matched case-insensitively on `lower`.
    const MARKERS: &[&str] = &[
        "password",
        "passwd",
        "api key",
        "api_key",
        "access token",
        "access_token",
        "secret key",
        "private key",
        "-----begin private key-----",
        "bearer ",
        "authorization: bearer",
    ];
    if MARKERS.iter().any(|m| lower.contains(m)) {
        return true;
    }
    // A long hex/base64 blob that looks like an encoded secret (≥40 chars). Blob
    // detection runs on the ORIGINAL (case-preserved) prompt: base64 is mixed-case,
    // and lowercasing would erase the uppercase that distinguishes a real secret
    // (a run of 2000 'a's must NOT match). Hex is matched case-insensitively.
    for tok in original.split_whitespace() {
        if tok.len() >= 40 && (is_hex_blob(tok) || is_base64_blob(tok)) {
            return true;
        }
    }
    false
}

/// All-hex token of the given length (allows `0x` prefix).
fn is_hex_blob(tok: &str) -> bool {
    let t = tok.strip_prefix("0x").unwrap_or(tok);
    // Require both a digit and a hex letter (case-insensitive): a real hex secret
    // has both; a run of 2000 'a's (all one hex letter) is prose, not a secret.
    t.len() >= 40
        && t.chars().all(|c| c.is_ascii_hexdigit())
        && t.chars().any(|c| c.is_ascii_digit())
        && t.chars().any(|c| matches!(c, 'a'..='f' | 'A'..='F'))
}

/// All-base64-alphabet token of the given length (may end in `=`/`==`).
fn is_base64_blob(tok: &str) -> bool {
    let core = tok.trim_end_matches('=');
    // Require mixed case: real base64 is mixed-case; a run of lowercase letters
    // is prose, not a secret.
    core.len() >= 40
        && core
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '/'))
        && core.chars().any(|c| c.is_ascii_uppercase())
        && core.chars().any(|c| c.is_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ConductorTaskClass as T;

    fn classify(prompt: &str) -> TurnClassification {
        RuleBasedTurnClassifier.classify(prompt)
    }

    fn preds(c: &TurnClassification) -> Vec<&str> {
        c.feature_predicates.iter().map(String::as_str).collect()
    }

    // ── §5.1  rule fixtures → expected task_class ─────────────────────────────

    #[test]
    fn coding_prompt_with_codeblock() {
        let c = classify("Fix this:\n```rust\nfn main() {}\n```\n");
        assert_eq!(c.task_class, T::Coding);
        assert!(preds(&c).contains(&"has_codeblock"));
    }

    #[test]
    fn coding_prompt_with_inline_code() {
        let c = classify("Call `foo()` and return the value.");
        assert_eq!(c.task_class, T::Coding);
        assert!(preds(&c).contains(&"has_inline_code"));
        // A single inline-code line must NOT also register a fenced block.
        assert!(!preds(&c).contains(&"has_codeblock"));
    }

    #[test]
    fn planning_prompt() {
        let c = classify("Help me plan the rollout in steps.");
        assert_eq!(c.task_class, T::Planning);
        assert!(preds(&c).contains(&"planning_shaped"));
    }

    #[test]
    fn research_prompt() {
        let c = classify("Research the latest findings and cite sources.");
        assert_eq!(c.task_class, T::Research);
        assert!(preds(&c).contains(&"research_shaped"));
    }

    #[test]
    fn personal_data_prompt_health() {
        let c = classify("My doctor changed my medication, what should I do?");
        assert_eq!(c.task_class, T::PersonalData);
        assert!(preds(&c).contains(&"personal_data_shaped"));
    }

    #[test]
    fn credential_prompt_secret_word() {
        let c = classify("Here is my password: hunter2, store it.");
        assert_eq!(c.task_class, T::PersonalData); // credential ⇒ PersonalData precedence
        assert!(preds(&c).contains(&"credential_shaped"));
    }

    #[test]
    fn credential_prompt_hex_blob() {
        let c =
            classify("Token: 0xdeadbeefcafebabe1234567890abcdefdeadbeefcafebabe1234567890abcdef");
        assert_eq!(c.task_class, T::PersonalData);
        assert!(preds(&c).contains(&"credential_shaped"));
    }

    #[test]
    fn credential_prompt_mixed_case_base64_blob() {
        // Blob detection runs on the ORIGINAL prompt (base64 is mixed-case);
        // lowercasing would erase the uppercase that distinguishes a real secret.
        let blob = "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789aBcDeFgHiJkL"; // mixed case, ≥40
        let c = classify(&format!("Header: {blob}"));
        assert_eq!(c.task_class, T::PersonalData);
        assert!(preds(&c).contains(&"credential_shaped"));
    }

    #[test]
    fn tool_request_prompt() {
        let c = classify("Please run build.sh in the terminal.");
        assert_eq!(c.task_class, T::ToolUse);
        assert!(preds(&c).contains(&"tool_request"));
        assert!(preds(&c).contains(&"has_file_path")); // build.sh
    }

    #[test]
    fn chat_prompt_plain_greeting() {
        let c = classify("Hey, how are you today?");
        assert_eq!(c.task_class, T::Chat);
        assert!(
            c.feature_predicates.is_empty(),
            "{:?}",
            c.feature_predicates
        );
    }

    // ── §5.2  sorted, deduped, allowlisted ────────────────────────────────────

    #[test]
    fn predicates_are_sorted_in_canonical_order() {
        // Fire several predicates; output must be canonical (as_str alphabetical) order.
        let c = classify("Run deploy app.py\n```py\nx=1\n```\nmy password is x\nplan the steps");
        // Canonical order: credential_shaped, has_codeblock, has_file_path, long_prompt,
        // personal_data_shaped, planning_shaped, research_shaped, tool_request.
        // (has_inline_code absent here.) We don't assert exact membership order via
        // indices; we assert the vec equals its canonical-sorted form AND every element
        // is a known as_str.
        let mut sorted = c.feature_predicates.clone();
        sorted.sort();
        // Canonical alphabetical sort must match emitted order (iterating ALL in order).
        assert_eq!(
            c.feature_predicates, sorted,
            "must be alphabetically sorted"
        );
        let known: Vec<&str> = FeaturePredicate::ALL.iter().map(|p| p.as_str()).collect();
        for p in &c.feature_predicates {
            assert!(
                known.contains(&p.as_str()),
                "non-allowlisted predicate: {p}"
            );
        }
    }

    #[test]
    fn predicates_are_deduped() {
        // A prompt with two code blocks should still emit has_codeblock exactly once.
        let c = classify("```rs\na\n```\nand\n```rs\nb\n```");
        let count = c
            .feature_predicates
            .iter()
            .filter(|p| p.as_str() == "has_codeblock")
            .count();
        assert_eq!(count, 1, "has_codeblock emitted {count} times, expected 1");
    }

    #[test]
    fn no_free_form_predicate_strings() {
        // Every emitted element must be exactly a FeaturePredicate::as_str().
        let known: Vec<&str> = FeaturePredicate::ALL.iter().map(|p| p.as_str()).collect();
        let long = "a".repeat(LONG_PROMPT_THRESHOLD);
        let cases = [
            "Fix ```x```",
            "my bank account",
            "run test foo",
            long.as_str(),
        ];
        for prompt in cases {
            let c = classify(prompt);
            for p in &c.feature_predicates {
                assert!(
                    known.contains(&p.as_str()),
                    "free-form predicate {p} from: {prompt}"
                );
            }
        }
    }

    // ── §5.6  fail-closed ─────────────────────────────────────────────────────

    #[test]
    fn empty_prompt_fails_closed_to_unknown() {
        let c = classify("");
        assert_eq!(c.task_class, T::Unknown);
        assert!(c.feature_predicates.is_empty());
        assert_eq!(c.source, ClassifierSource::RuleBasedV1);
    }

    #[test]
    fn whitespace_only_prompt_fails_closed_to_unknown() {
        let c = classify("   \n\t  ");
        assert_eq!(c.task_class, T::Unknown);
        assert!(c.feature_predicates.is_empty());
    }

    #[test]
    fn classifier_is_infallible_never_panics() {
        // The trait contract: classify never panics on any input. Exercise odd inputs.
        for prompt in ["", " \t\n ", "🎉🎊 unicode", "\u{0}", "👋 ℕ 𝕠"] {
            let _ = classify(prompt); // must not panic
        }
    }

    // ── detector unit tests (keep the rules honest) ───────────────────────────

    #[test]
    fn codeblock_detects_fenced_not_inline() {
        assert!(has_codeblock("```\ncode\n```"));
        assert!(has_codeblock("text\n  ```rs\nx\n```"));
        assert!(!has_codeblock("call `foo`"));
    }

    #[test]
    fn inline_code_excludes_fence_lines() {
        assert!(has_inline_code("use `foo`"));
        assert!(!has_inline_code("```\ncode\n```")); // fence only, no inline span
    }

    #[test]
    fn personal_data_requires_phrase_not_word() {
        // "bank" alone must not fire; "my bank" must.
        assert!(!is_personal_data_shaped("the river bank is full"));
        assert!(is_personal_data_shaped("check my bank balance"));
    }

    #[test]
    fn tool_request_excludes_free_text_run() {
        // "run an idea by you" must NOT fire (no command-shaped follower).
        assert!(!is_tool_request("I want to run an idea by you"));
        assert!(is_tool_request("please run build.sh now"));
    }

    #[test]
    fn long_prompt_threshold() {
        // Threshold is in CHARS (prompt.chars().count()), not bytes: a multibyte
        // prompt must not trip the byte-length path early.
        let short = classify(&"a".repeat(LONG_PROMPT_THRESHOLD - 1));
        assert!(!preds(&short).contains(&"long_prompt"));
        let long = classify(&"a".repeat(LONG_PROMPT_THRESHOLD));
        assert!(preds(&long).contains(&"long_prompt"));
        // A long chat (no other signal) is still Chat, not Unknown.
        assert_eq!(long.task_class, T::Chat);
    }

    #[test]
    fn long_prompt_threshold_is_chars_not_bytes() {
        // 600 emojis = 600 chars but 2400 bytes. Must NOT fire long_prompt (chars < 2000)
        // even though bytes >= 2000.
        let emoji = "🎉".repeat(600);
        assert!(
            emoji.len() >= LONG_PROMPT_THRESHOLD,
            "sanity: byte length crossed"
        );
        let c = classify(&emoji);
        assert!(!preds(&c).contains(&"long_prompt"));
        // ...but 2001 emojis do fire.
        let big = "🎉".repeat(LONG_PROMPT_THRESHOLD + 1);
        assert!(preds(&classify(&big)).contains(&"long_prompt"));
    }

    #[test]
    fn source_tag_present() {
        assert_eq!(classify("hi").source, ClassifierSource::RuleBasedV1);
    }

    // ── M4-B acceptance: policy authority invariant (§5.5) ────────────────────

    /// Build a ConductorTurnContext from a classified prompt (mirrors what
    /// session::build_turn_context_with_classifier produces).
    fn ctx_from_prompt(prompt: &str) -> crate::conductor::recipe::ConductorTurnContext {
        use crate::conductor::recipe::{ConductorTurnContext, PrivacyLane};
        let cls = RuleBasedTurnClassifier.classify(prompt);
        ConductorTurnContext {
            request_id: "req".to_string(),
            task_class: cls.task_class,
            feature_predicates: cls.feature_predicates,
            privacy_lane: PrivacyLane::LocalOnly,
            available_workers: Vec::new(),
            working_directory: None,
            deadline_ms: None,
        }
    }

    #[test]
    fn static_direct_policy_authority_fields_unchanged_by_classification() {
        // The no-egress-change proof: classifying the context does NOT change any
        // authority-carrying field of the route decision (StaticDirectPolicy is
        // M1-inert to task_class). `task_class` is metadata and is EXPECTED to
        // differ — it is explicitly excluded from the equality assertion.
        use crate::conductor::policy::{ConductorRoutingPolicy, StaticDirectPolicy};
        let policy = StaticDirectPolicy;
        let classified = ctx_from_prompt("my password is hunter2, classify me");
        let unknown = ctx_from_prompt("");
        // Sanity: the two contexts really do differ in task_class (the point).
        assert_ne!(classified.task_class, unknown.task_class);
        assert!(!classified.feature_predicates.is_empty());
        let d_cls = policy.decide(&classified);
        let d_unk = policy.decide(&unknown);
        // Authority-carrying fields MUST be identical.
        assert_eq!(d_cls.recipe_id, d_unk.recipe_id);
        assert_eq!(d_cls.topology, d_unk.topology);
        assert_eq!(d_cls.worker_id, d_unk.worker_id);
        assert_eq!(d_cls.lane, d_unk.lane);
        assert_eq!(d_cls.approval, d_unk.approval);
        assert_eq!(d_cls.reason, d_unk.reason);
    }

    // ── M4-B acceptance: corpus_match flips None → Some (§5.4) ────────────────

    #[test]
    fn classified_context_flips_corpus_match_none_to_some() {
        // The degenerate-dimension unlock: a content-blind context (Unknown + [])
        // matches ZERO corpus entries; the classified context (PersonalData +
        // credential_shaped) matches an entry sharing the EXACT predicate string.
        use crate::conductor::eval::{
            Corpus, CorpusEntry, CorpusEntrySource, IdealApprovalLabel, IdealRouteLabel,
        };
        use crate::conductor::recipe::ConductorTopology;
        use crate::conductor::shadow::match_corpus_entry;
        let entry = CorpusEntry {
            id: "e1".to_string(),
            source: CorpusEntrySource::SyntheticCore,
            task_class: ConductorTaskClass::PersonalData,
            feature_predicates: vec!["credential_shaped".to_string()],
            privacy_lane: crate::conductor::recipe::PrivacyLane::LocalOnly,
            available_workers: Vec::new(),
            ideal_route: IdealRouteLabel {
                recipe_id: "r".to_string(),
                topology: ConductorTopology::Direct,
                worker_id: "w".to_string(),
                approval: IdealApprovalLabel::None,
            },
            redacted_text_excerpt: None,
            membrane: None,
        };
        let corpus = Corpus {
            schema_version: 1,
            corpus_version: "test".to_string(),
            annotator: "test".to_string(),
            notes: None,
            entries: vec![entry],
        };
        // Content-blind baseline: Unknown + [] ⇒ no match.
        let unknown = ctx_from_prompt("");
        assert!(match_corpus_entry(&corpus, &unknown).is_none());
        // Classified: PersonalData + credential_shaped ⇒ Some (exact-string match).
        let classified = ctx_from_prompt("my password is hunter2");
        assert_eq!(classified.task_class, ConductorTaskClass::PersonalData);
        let matched = match_corpus_entry(&corpus, &classified);
        assert!(matched.is_some(), "classified context must match");
        assert_eq!(matched.unwrap().id, "e1");
    }

    #[test]
    fn source_as_str_canonical() {
        assert_eq!(ClassifierSource::RuleBasedV1.as_str(), "rule-based-v1");
    }
}
