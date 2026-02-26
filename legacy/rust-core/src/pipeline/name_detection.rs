//! Name mention detection and wake-word canonicalization.
//!
//! Extracted from `coordinator.rs` — these are pure functions with no
//! pipeline state dependencies.

use crate::intent;

/// Extract the user's query from text surrounding a name mention match.
///
/// Prefers text after the name ("Fae, how are you?" → "how are you?"),
/// falls back to text before it ("Hello Fae" → "Hello"), then defaults to
/// "Hello" if the name was the entire utterance.
pub(crate) fn extract_query_around_name(text: &str, pos: usize, matched_len: usize) -> String {
    let after = &text[pos + matched_len..];
    let after = after.trim_start_matches([',', ':', '.', '!', '?', ' ']);
    let after = after.trim();

    if !after.is_empty() {
        return after.to_owned();
    }

    let before = &text[..pos];
    let before = before.trim_end_matches([',', ':', '.', '!', '?', ' ']);
    let before = before.trim();
    if before.is_empty() {
        "Hello".to_owned()
    } else {
        before.to_owned()
    }
}

/// Check if the assistant's name ("fae") appears in text as a standalone word.
///
/// This is used during Active state for name-gated barge-in: saying "Fae,
/// stop that" should interrupt the assistant.
/// Returns `(byte_pos, matched_len)` of the first standalone name match, or
/// `None` if the name doesn't appear.
pub(crate) fn find_name_mention(lower_raw: &str) -> Option<(usize, usize)> {
    let variants = intent::FAE_NAME_VARIANTS;

    let mut best: Option<(usize, usize)> = None;
    for v in variants {
        let mut search_from = 0;
        while search_from < lower_raw.len() {
            let haystack = &lower_raw[search_from..];
            let Some(rel_pos) = haystack.find(v) else {
                break;
            };
            let pos = search_from + rel_pos;
            let end = pos + v.len();

            // Word boundary check to avoid false positives ("coffee" matching "fee").
            let start_ok = pos == 0 || !lower_raw.as_bytes()[pos - 1].is_ascii_alphanumeric();
            let end_ok =
                end >= lower_raw.len() || !lower_raw.as_bytes()[end].is_ascii_alphanumeric();

            if start_ok && end_ok {
                let candidate = (pos, v.len());
                best = match best {
                    None => Some(candidate),
                    Some(prev) if candidate.0 < prev.0 => Some(candidate),
                    Some(prev) => Some(prev),
                };
                break;
            }
            search_from = pos + 1;
        }
    }
    best
}

/// Canonicalize STT output that may have mis-transcribed "Fae" as a variant.
///
/// Only rewrites the first wake-like token near the start of the utterance.
pub(crate) fn canonicalize_wake_word_transcription(wake_word: &str, text: &str) -> Option<String> {
    let wake = wake_word.trim().to_ascii_lowercase();

    // Only perform canonicalization for wake words containing "fae".
    if !wake.contains("fae") {
        return None;
    }

    let original = text;
    let trimmed = original.trim_start();
    let base_off = original.len().saturating_sub(trimmed.len());
    if trimmed.is_empty() {
        return None;
    }

    let lower = trimmed.to_ascii_lowercase();
    let canonical = "Fae";
    let fae_variants = intent::FAE_NAME_VARIANTS;

    fn boundary_ok(s: &str, at: usize) -> bool {
        if at >= s.len() {
            return true;
        }
        matches!(
            s.as_bytes()[at],
            b' ' | b'\t' | b'\n' | b'\r' | b',' | b'.' | b'!' | b'?' | b':' | b';'
        )
    }

    // Direct: "fee, ...", "fay ..."
    for v in fae_variants {
        if lower.starts_with(v) && boundary_ok(&lower, v.len()) {
            let start = base_off;
            let end = start + v.len();
            if end <= original.len() && end > start {
                let mut out = original.to_owned();
                out.replace_range(start..end, canonical);
                return Some(out);
            }
        }
    }

    // Common prefixed forms: "hey fee", "hi fee", "hello fee", "hello, fee", etc.
    let prefixes = [
        "hey ", "hey, ", "hi ", "hi, ", "high ", "high, ", "hello ", "hello, ", "ok ", "ok, ",
        "okay ", "okay, ",
    ];
    for prefix in prefixes.iter().copied() {
        if let Some(after) = lower.strip_prefix(prefix) {
            for v in fae_variants {
                if after.starts_with(v) && boundary_ok(after, v.len()) {
                    let start = base_off + prefix.len();
                    let end = start + v.len();
                    if end <= original.len() && end > start {
                        let mut out = original.to_owned();
                        out.replace_range(start..end, canonical);
                        return Some(out);
                    }
                }
            }
        }
    }

    None
}
