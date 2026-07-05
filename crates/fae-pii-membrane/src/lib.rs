//! PII egress membrane — canonical Rust port of the Swift `SensitiveContentPolicy`.
//!
//! Detects and redacts secret-shaped content before it egresses to a cloud-backed
//! model/provider, and governs local persistence of sensitive observations. This is
//! the **egress** counterpart to `fae-envelope-gate` (the **ingress** gate): together
//! they form the single trust boundary around untrusted input (peers) and untrusted
//! output (cloud providers).
//!
//! # Why this exists in Rust (not Swift)
//!
//! See ADR-011 + `docs/research/fae-learned-conductor-m2-decisions-2026-06-22.md`
//! (D-M2-4): the membrane is egress-critical + per-turn hot-path + must outlive the
//! Swift app + small, so it is PORTED (no bridge, ever). The Rust `regex` crate is
//! linear-time, which makes this port **ReDoS-resistant** by construction — a
//! security improvement over `NSRegularExpression`.
//!
//! # Parity
//!
//! Behavioral parity with `native/macos/Fae/Sources/Fae/Core/SensitiveContentPolicy.swift`
//! is asserted by golden tests ported from `SensitiveContentPolicyTests.swift`. The
//! Swift impl remains as legacy until the daemon runs headless; this crate is the
//! canonical authority for the conductor's cloud-routing path.

#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

use std::sync::OnceLock;

/// Sensitivity tier for a scanned region of text, ordered least→most sensitive so
/// `>=` comparisons implement the thresholds. Mirrors the Swift `SensitivityLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SensitivityLevel {
    /// No rule matched.
    Normal = 0,
    /// Sensitive content present inline (e.g. a one-time-code mention), enough to
    /// block delegation but not necessarily cloud egress.
    SensitiveInline = 1,
    /// Looks like a credential (API key, opaque token). Blocks cloud egress.
    LikelyCredential = 2,
    /// High-severity secret (private key block, seed phrase, password assignment).
    HighlySensitive = 3,
}

/// Result of scanning a region of text. Carries structured labels only — never the
/// matched text — so it is safe to surface in failure telemetry without leaking the
/// secret it detected.
#[derive(Debug, Clone)]
pub struct ScanResult {
    /// The highest severity tier any rule reached.
    pub level: SensitivityLevel,
    /// The labels of every rule that matched, in definition order.
    pub matched_labels: Vec<String>,
}

impl ScanResult {
    /// Any rule matched at all.
    pub fn contains_sensitive_content(&self) -> bool {
        self.level != SensitivityLevel::Normal
    }

    /// Structured extraction (memory facts, etc.) should be suppressed. Threshold:
    /// `>= LikelyCredential`.
    pub fn should_suppress_structured_extraction(&self) -> bool {
        self.level >= SensitivityLevel::LikelyCredential
    }

    /// Delegation to another agent should be blocked. Threshold: `>= SensitiveInline`
    /// (more aggressive than remote-egress blocking, by design — delegate prompts are
    /// less protected than a direct remote call).
    pub fn should_block_delegation(&self) -> bool {
        self.level >= SensitivityLevel::SensitiveInline
    }
}

/// A static rule definition (label + tier + regex source), before compilation.
struct RawRule {
    label: &'static str,
    level: SensitivityLevel,
    pattern: &'static str,
}

/// A compiled rule. The `regex` is owned; the label/level are borrowed from static.
struct CompiledRule {
    label: &'static str,
    level: SensitivityLevel,
    regex: regex::Regex,
}

// The 13 detection rules. Most are ported byte-for-byte from the Swift source; a
// few are intentional egress-hardening divergences (the case-insensitive PEM rule
// and the AWS `AKIA…` rule below). Patterns use only features the Rust linear-time
// `regex` engine supports (no lookbehind / backreferences), so every pattern
// compiles — asserted at init (fail-closed) and by `all_rules_compile`.
const RAW_RULES: &[RawRule] = &[
    RawRule {
        label: "private_key_block",
        level: SensitivityLevel::HighlySensitive,
        // INTENTIONAL HARDENING over the Swift source (advisor impl-review
        // 2026-06-22): this crate is the CANONICAL egress authority, so a known
        // private-key miss is a real risk, not a parity nicety. The Swift regex
        // `-----BEGIN (?:RSA |EC |OPENSSH |PGP |PRIVATE)KEY-----` only matched
        // abbreviated forms and MISSED every canonical PEM header
        // (`-----BEGIN RSA PRIVATE KEY-----`, `... OPENSSH PRIVATE KEY-----`, etc.).
        // This pattern catches the real PKCS#1 / PKCS#8 / OpenSSH / PGP private
        // key headers. Marked as a deliberate divergence from Swift, not parity.
        // `(?i)`: PEM headers are conventionally upper-case, but a lower-case
        // (or mixed-case) header still names a private key and MUST be caught.
        pattern: r"(?i)-----BEGIN (?:RSA |DSA |EC |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----",
    },
    RawRule {
        label: "seed_phrase",
        level: SensitivityLevel::HighlySensitive,
        pattern: r"(?i)\b(?:seed phrase|recovery phrase|mnemonic phrase|wallet seed)\b",
    },
    RawRule {
        label: "password_assignment",
        level: SensitivityLevel::HighlySensitive,
        pattern: r"(?i)\b(?:my |the )?(?:password|passphrase|pin)\b\s*(?:is|=|:)\s*[^\s,;]+",
    },
    RawRule {
        label: "api_key_assignment",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"(?i)\b(?:api[_ -]?key|access[_ -]?token|auth[_ -]?token|bearer token|secret key|client secret)\b\s*(?:is|=|:)\s*[^\s,;]+",
    },
    RawRule {
        label: "openai_key",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"(?i)\bsk-[A-Za-z0-9]{12,}\b",
    },
    RawRule {
        label: "github_token",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"(?i)\bgh[pousr]_[A-Za-z0-9]{16,}\b",
    },
    RawRule {
        label: "slack_token",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b",
    },
    RawRule {
        label: "google_key",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"(?i)\bAIza[0-9A-Za-z\-_]{20,}\b",
    },
    RawRule {
        // AWS access key IDs are exactly 20 chars (`AKIA` + 16 upper-alnum), so they
        // slip UNDER the 40-char `long_opaque_token` catch-all. Case-sensitive by
        // spec (AWS emits upper-case). Intentional hardening, not Swift parity.
        label: "aws_access_key",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"\bAKIA[0-9A-Z]{16}\b",
    },
    RawRule {
        label: "ssh_key",
        level: SensitivityLevel::HighlySensitive,
        pattern: r"(?i)\bssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,}",
    },
    RawRule {
        label: "one_time_code",
        level: SensitivityLevel::SensitiveInline,
        pattern: r"(?i)\b(?:one[- ]time code|verification code|otp|2fa code|totp|mfa code)\b",
    },
    RawRule {
        label: "credential_phrase",
        level: SensitivityLevel::SensitiveInline,
        pattern: r"(?i)\b(?:login token|session token|cookie value|backup code|recovery code)\b",
    },
    RawRule {
        label: "long_opaque_token",
        level: SensitivityLevel::LikelyCredential,
        pattern: r"\b[A-Za-z0-9+/=_-]{40,}\b",
    },
];

/// Compile a raw rule table, failing if ANY pattern is invalid. Pure — no process
/// env, no globals — so the fail-closed invariant is unit-testable with a
/// deliberately-broken table. On success every raw rule has a compiled counterpart
/// (`out.len() == raw.len()`); a `filter_map(...ok())` would instead silently DROP
/// a broken rule and let the secret it guards egress un-scanned.
fn compile_rules(raw: &[RawRule]) -> Result<Vec<CompiledRule>, String> {
    let mut out = Vec::with_capacity(raw.len());
    for r in raw {
        let regex = regex::Regex::new(r.pattern)
            .map_err(|e| format!("rule {:?} failed to compile: {e}", r.label))?;
        out.push(CompiledRule {
            label: r.label,
            level: r.level,
            regex,
        });
    }
    if out.len() != raw.len() {
        return Err(format!(
            "compiled {} of {} rules (table integrity broken)",
            out.len(),
            raw.len()
        ));
    }
    Ok(out)
}

/// Lazily compile all rules once and cache them for the process lifetime. FAIL
/// CLOSED: if any pattern fails to compile (a `RAW_RULES` regression), abort the
/// process rather than serve with an incomplete egress membrane — a silently
/// dropped rule is a hole through which a secret could leave un-scanned.
fn compiled_rules() -> &'static [CompiledRule] {
    static RULES: OnceLock<Vec<CompiledRule>> = OnceLock::new();
    RULES.get_or_init(|| match compile_rules(RAW_RULES) {
        Ok(rules) => rules,
        Err(e) => {
            eprintln!(
                "FATAL: fae-pii-membrane egress rule table failed to initialize: {e}. \
                 Refusing to run with an incomplete membrane."
            );
            std::process::abort();
        }
    })
}

/// Scan `text` for sensitive content. Returns the highest severity reached and the
/// labels of every matching rule. Empty input scans clean.
pub fn scan(text: &str) -> ScanResult {
    if text.is_empty() {
        return ScanResult {
            level: SensitivityLevel::Normal,
            matched_labels: Vec::new(),
        };
    }
    let mut max_level = SensitivityLevel::Normal;
    let mut labels = Vec::new();
    for rule in compiled_rules() {
        if rule.regex.is_match(text) {
            labels.push(rule.label.to_string());
            if rule.level > max_level {
                max_level = rule.level;
            }
        }
    }
    ScanResult {
        level: max_level,
        matched_labels: labels,
    }
}

/// Redact every secret-shaped match in `text` with `[REDACTED_SENSITIVE]`, for safe
/// persistence (memory episodes, logs). Order matches the Swift impl (rules applied
/// in definition order, each `replace_all` over the running output).
pub fn redact_for_storage(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let mut output = text.to_string();
    for rule in compiled_rules() {
        output = rule
            .regex
            .replace_all(&output, "[REDACTED_SENSITIVE]")
            .into_owned();
    }
    output
}

/// Should a cloud-bound route carrying `text` be blocked? Threshold:
/// `>= LikelyCredential`. This is the conductor's egress gate.
pub fn should_block_remote_egress(text: &str) -> bool {
    scan(text).level >= SensitivityLevel::LikelyCredential
}

/// Should a proactive observation be persisted? Non-observation tasks always persist.
/// Observation tasks (`camera_presence_check`, `screen_activity_check`) are withheld
/// when the text is sensitive OR mentions a protected subject (finance, health,
/// private messaging, password managers).
pub fn should_persist_proactive_observation(task_id: &str, text: &str) -> bool {
    const OBSERVATION_TASKS: &[&str] = &["camera_presence_check", "screen_activity_check"];
    if !OBSERVATION_TASKS.contains(&task_id) {
        return true;
    }
    if scan(text).contains_sensitive_content() {
        return false;
    }
    const PROTECTED_KEYWORDS: &[&str] = &[
        "1password",
        "lastpass",
        "bitwarden",
        "password manager",
        "passkey",
        "bank",
        "banking",
        "account balance",
        "credit card",
        "card number",
        "routing number",
        "inbox",
        "private message",
        "text thread",
        "imessage",
        "whatsapp",
        "signal",
        "medical",
        "diagnosis",
        "prescription",
        "patient",
        "lab result",
        "social security",
    ];
    let lower = text.to_lowercase();
    !PROTECTED_KEYWORDS.iter().any(|kw| lower.contains(kw))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Golden parity tests (ported from SensitiveContentPolicyTests.swift) ──────

    // Port of testScanDetectsLikelyCredential.
    #[test]
    fn scan_detects_likely_credential() {
        let result = scan("my API key is sk-abcdefghijklmnopqrstuvwxyz");
        assert!(result.contains_sensitive_content());
        assert!(result.level >= SensitivityLevel::LikelyCredential);
    }

    // Port of testRedactForStorageRemovesSecretLookingMaterial.
    #[test]
    fn redact_for_storage_removes_secret_looking_material() {
        let redacted = redact_for_storage("password = hunter2");
        assert!(!redacted.contains("hunter2"));
        assert!(redacted.contains("[REDACTED_SENSITIVE]"));
    }

    // Port of testRemoteEgressBlockDetectsCredentialStylePrompt.
    #[test]
    fn remote_egress_block_detects_credential_style_prompt() {
        assert!(should_block_remote_egress("Here is my password: hunter2"));
        assert!(should_block_remote_egress(
            "Attached secret key = sk-abcdefghijklmnopqrstuvwxyz"
        ));
        assert!(!should_block_remote_egress(
            "Summarize this README and list the next steps."
        ));
    }

    // ── Compile / table integrity ───────────────────────────────────────────────

    #[test]
    fn all_rules_compile() {
        // Every static pattern must compile and produce a compiled counterpart:
        // count parity is the fail-closed invariant (`compiled_rules` aborts the
        // process otherwise, so reaching this assert already proves no rule was
        // dropped).
        assert_eq!(compiled_rules().len(), RAW_RULES.len());
    }

    #[test]
    fn broken_rule_table_is_rejected_fail_closed() {
        // A deliberately-invalid regex must make `compile_rules` ERROR (its caller
        // aborts, failing closed) rather than silently drop the rule. Building the
        // membrane must be all-or-nothing, never partial.
        let bad = [RawRule {
            label: "deliberately_broken",
            level: SensitivityLevel::LikelyCredential,
            pattern: "(unterminated",
        }];
        assert!(
            compile_rules(&bad).is_err(),
            "an invalid pattern must fail compilation, not be skipped"
        );
        // And the real table compiles fully, with count parity (no silent drops).
        let good = compile_rules(RAW_RULES).expect("real RAW_RULES table must compile");
        assert_eq!(good.len(), RAW_RULES.len());
    }

    // ── AWS access-key hardening (S-H2: 20-char AKIA slips the 40-char catch-all) ─

    #[test]
    fn aws_access_key_id_is_blocked() {
        // Built by concatenation so no secret-shaped literal reaches git.
        let key = format!("{}{}", "AKIA", "IOSFODNN7EXAMPLE");
        let text = format!("aws access key {key} for the bucket");
        let result = scan(&text);
        assert!(
            result.matched_labels.iter().any(|l| l == "aws_access_key"),
            "AKIA key not caught; got {:?}",
            result.matched_labels
        );
        assert!(result.level >= SensitivityLevel::LikelyCredential);
        assert!(should_block_remote_egress(&text));
    }

    // ── PEM case-insensitivity (S-H2: lower/mixed-case headers are still keys) ────

    #[test]
    fn pem_header_detection_is_case_insensitive() {
        for header in [
            "-----begin rsa private key-----",
            "-----Begin OpenSSH Private Key-----",
        ] {
            let result = scan(header);
            assert!(
                result
                    .matched_labels
                    .iter()
                    .any(|l| l == "private_key_block"),
                "case-variant PEM header {header:?} was NOT caught"
            );
            assert!(should_block_remote_egress(header));
        }
    }

    // ── Per-label coverage: each rule fires and reports its tier ─────────────────

    #[test]
    fn every_rule_fires_on_a_real_sample() {
        // (sample, expected_label, min_level)
        let cases: &[(&str, &str, SensitivityLevel)] = &[
            (
                "-----BEGIN RSA PRIVATE KEY-----",
                "private_key_block",
                SensitivityLevel::HighlySensitive,
            ),
            (
                "my seed phrase is abandon about",
                "seed_phrase",
                SensitivityLevel::HighlySensitive,
            ),
            (
                "my password is hunter2",
                "password_assignment",
                SensitivityLevel::HighlySensitive,
            ),
            (
                "api key = abc123def",
                "api_key_assignment",
                SensitivityLevel::LikelyCredential,
            ),
            (
                "token sk-abcdefghijklmn",
                "openai_key",
                SensitivityLevel::LikelyCredential,
            ),
            (
                "ghp_abcdefghijklmnop",
                "github_token",
                SensitivityLevel::LikelyCredential,
            ),
            (
                "xoxb-abcdefghij",
                "slack_token",
                SensitivityLevel::LikelyCredential,
            ),
            (
                "key AIza0123456789abcdefghij",
                "google_key",
                SensitivityLevel::LikelyCredential,
            ),
            (
                "ssh-rsa AAAAB3NzaC1yc2EAAAAC1yc2E",
                "ssh_key",
                SensitivityLevel::HighlySensitive,
            ),
            (
                "enter the otp now",
                "one_time_code",
                SensitivityLevel::SensitiveInline,
            ),
            (
                "found a session token here",
                "credential_phrase",
                SensitivityLevel::SensitiveInline,
            ),
            (
                "blob abcdefghijklmnopqrstuvwxyz0123456789ABCD",
                "long_opaque_token",
                SensitivityLevel::LikelyCredential,
            ),
        ];
        for (sample, expected_label, min_level) in cases {
            let result = scan(sample);
            assert!(
                result.matched_labels.iter().any(|l| l == expected_label),
                "sample {sample:?} did not trigger {expected_label}; got {:?}",
                result.matched_labels
            );
            assert!(
                result.level >= *min_level,
                "sample {sample:?} level {:?} < {min_level:?}",
                result.level
            );
        }
    }

    // ── PEM hardening (advisor impl-review: canonical headers must be caught) ────

    #[test]
    fn canonical_pem_private_key_headers_are_caught() {
        // Every real PEM private-key header format. The Swift source missed all
        // of these; the hardened Rust regex (intentional divergence) catches them.
        let headers = [
            "-----BEGIN PRIVATE KEY-----",           // PKCS#8
            "-----BEGIN RSA PRIVATE KEY-----",       // PKCS#1 RSA
            "-----BEGIN EC PRIVATE KEY-----",        // SEC1 EC
            "-----BEGIN DSA PRIVATE KEY-----",       // DSA
            "-----BEGIN OPENSSH PRIVATE KEY-----",   // OpenSSH (ed25519 etc.)
            "-----BEGIN ENCRYPTED PRIVATE KEY-----", // PKCS#8 encrypted
            "-----BEGIN PGP PRIVATE KEY BLOCK-----", // PGP
        ];
        for h in headers {
            let result = scan(h);
            assert!(
                result
                    .matched_labels
                    .iter()
                    .any(|l| l == "private_key_block"),
                "canonical PEM header {h:?} was NOT caught (regression of the hardening fix)"
            );
            assert_eq!(result.level, SensitivityLevel::HighlySensitive);
            // The whole point: it must block remote egress.
            assert!(should_block_remote_egress(h));
        }
    }

    #[test]
    fn redact_for_storage_strips_pem_header_and_body() {
        // The egress-detection fix (canonical_pem...) catches the header; this test
        // proves the STORAGE-redaction API does not leak the base64 body either.
        // The body lines are 62 chars of the base64 alphabet, so long_opaque_token
        // ({40,}) redacts them; private_key_block redacts the header. The footer
        // (`-----END ...-----`) is a non-secret structural marker and may survive.
        let body_line = "MIIEowIBAAKCAQEA0Z3VS5JJcds3xfnygWyF7EXampleFAKEkeyNotRealXXXpad";
        assert!(
            body_line.len() >= 40,
            "fixture: body line must be >=40 chars"
        );
        let pem = format!(
            "-----BEGIN RSA PRIVATE KEY-----\n{body_line}\n{body_line}\n-----END RSA PRIVATE KEY-----"
        );
        let redacted = redact_for_storage(&pem);
        assert!(
            !redacted.contains("FAKEkeyNotReal"),
            "PEM body survived redaction"
        );
        assert!(
            !redacted.contains(body_line),
            "PEM body line survived redaction"
        );
        assert!(
            !redacted.contains("BEGIN RSA PRIVATE KEY"),
            "PEM header survived redaction"
        );
        assert!(redacted.contains("[REDACTED_SENSITIVE]"));
    }

    // ── Threshold distinction (the advisor's point: delegation ≠ egress) ────────

    #[test]
    fn delegation_threshold_is_more_aggressive_than_egress() {
        // "otp" is SensitiveInline: blocks delegation but NOT remote egress.
        let result = scan("the otp is 123456");
        assert!(
            result.should_block_delegation(),
            "SensitiveInline must block delegation"
        );
        assert!(
            !should_block_remote_egress("the otp is 123456"),
            "SensitiveInline must NOT block remote egress (threshold is LikelyCredential)"
        );
    }

    #[test]
    fn benign_text_scans_clean() {
        let result = scan("What's the weather in Edinburgh today?");
        assert!(!result.contains_sensitive_content());
        assert!(result.matched_labels.is_empty());
        assert!(!result.should_block_delegation());
        assert!(!should_block_remote_egress(
            "What's the weather in Edinburgh today?"
        ));
    }

    // ── Proactive observation policy ────────────────────────────────────────────

    #[test]
    fn non_observation_tasks_always_persist() {
        assert!(should_persist_proactive_observation(
            "some_other_task",
            "my password is hunter2"
        ));
        assert!(should_persist_proactive_observation(
            "anything",
            "bank balance is 1000"
        ));
    }

    #[test]
    fn observation_task_with_sensitive_content_is_withheld() {
        assert!(!should_persist_proactive_observation(
            "camera_presence_check",
            "my api key is sk-abcdefghijklmn"
        ));
    }

    #[test]
    fn observation_task_with_protected_keyword_is_withheld() {
        assert!(!should_persist_proactive_observation(
            "screen_activity_check",
            "showing the bank login screen"
        ));
        assert!(!should_persist_proactive_observation(
            "camera_presence_check",
            "patient records visible"
        ));
    }

    #[test]
    fn observation_task_clean_is_persisted() {
        assert!(should_persist_proactive_observation(
            "camera_presence_check",
            "the desk is clear"
        ));
    }
}
