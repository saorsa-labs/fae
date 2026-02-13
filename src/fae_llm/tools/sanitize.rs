//! Tool output sanitization utilities.
//!
//! Strips likely binary/blob payloads (base64 or hex dumps) from tool output
//! before the content is fed back into the model context.
//!
//! This module handles **output sanitization** - cleaning tool output before
//! it's fed back to the LLM. For input sanitization (cleaning tool arguments),
//! see the `input_sanitize` module.

use crate::fae_llm::tools::types::truncate_output;

/// Minimum length for a token to be considered a base64 blob.
const MIN_BASE64_BLOB_LEN: usize = 256;
/// Minimum length for a token to be considered a hex blob.
const MIN_HEX_BLOB_LEN: usize = 128;

/// Sanitized tool output metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SanitizedOutput {
    /// Sanitized content, with binary-like blobs replaced.
    pub content: String,
    /// Number of blob tokens redacted.
    pub redacted_blobs: usize,
    /// Whether the output was truncated to fit byte budget.
    pub truncated: bool,
}

/// Sanitize and bound tool output text.
///
/// This function is designed for **content fields** (file content, command output).
/// It only removes null bytes and binary blobs, preserving shell syntax like
/// $, |, >, <, backticks, etc. that may be legitimate content.
///
/// For command arguments that will be executed, use `input_sanitize::sanitize_command_input`
/// which applies stricter filtering.
pub fn sanitize_tool_output(raw: &str, max_bytes: usize) -> SanitizedOutput {
    let mut redacted_blobs = 0usize;
    let mut token = String::new();
    let mut sanitized = String::with_capacity(raw.len());

    // First pass: remove null bytes (always dangerous)
    let raw = raw.replace('\x00', "");

    let flush_token = |token: &mut String, out: &mut String, redacted: &mut usize| {
        if token.is_empty() {
            return;
        }
        if let Some(kind) = classify_blob(token.as_str()) {
            // Keep the shell syntax characters around blobs for context
            let stripped = strip_shell_syntax(token);
            out.push_str(format!("[{kind} blob omitted: {} chars]", stripped.len()).as_str());
            *redacted = redacted.saturating_add(1);
        } else {
            out.push_str(token.as_str());
        }
        token.clear();
    };

    // Second pass: tokenize on whitespace and detect blobs
    for ch in raw.chars() {
        if ch.is_whitespace() {
            flush_token(&mut token, &mut sanitized, &mut redacted_blobs);
            sanitized.push(ch);
        } else {
            token.push(ch);
        }
    }
    flush_token(&mut token, &mut sanitized, &mut redacted_blobs);

    let (content, truncated) = truncate_output(&sanitized, max_bytes);
    SanitizedOutput {
        content,
        redacted_blobs,
        truncated,
    }
}

fn classify_blob(token: &str) -> Option<&'static str> {
    let stripped = strip_shell_syntax(token);
    if is_probably_hex_blob(&stripped) {
        return Some("hex");
    }
    if is_probably_base64_blob(&stripped) {
        return Some("base64");
    }
    None
}

/// Strip shell syntax characters for blob detection, but preserve them in output.
fn strip_shell_syntax(token: &str) -> String {
    token
        .chars()
        .filter(|c| {
            // Keep alphanumeric, common punctuation, and whitespace
            // Remove shell metacharacters for detection purposes only
            !matches!(
                c,
                '$' | '`' | '|' | '>' | '<' | ';' | '&' | '\\' | '\n' | '\r' | '\t'
            )
        })
        .collect()
}

fn is_probably_hex_blob(s: &str) -> bool {
    s.len() >= MIN_HEX_BLOB_LEN && s.chars().all(|c| c.is_ascii_hexdigit())
}

fn is_probably_base64_blob(s: &str) -> bool {
    if s.len() < MIN_BASE64_BLOB_LEN {
        return false;
    }

    let mut valid = 0usize;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=' | '-' | '_') {
            valid += 1;
        } else {
            return false;
        }
    }

    valid.saturating_mul(100) / s.len() >= 98
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_large_hex_blob() {
        let hex = "a".repeat(256);
        let input = format!("prefix {hex} suffix");
        let out = sanitize_tool_output(&input, 1024);
        assert_eq!(out.redacted_blobs, 1);
        assert!(out.content.contains("[hex blob omitted: 256 chars]"));
        assert!(out.content.contains("prefix"));
        assert!(out.content.contains("suffix"));
    }

    #[test]
    fn redacts_large_base64_blob() {
        let base64 = "QWxhZGRpbjpvcGVuIHNlc2FtZQ==".repeat(12);
        let out = sanitize_tool_output(&base64, 1024);
        assert_eq!(out.redacted_blobs, 1);
        assert!(out.content.contains("[base64 blob omitted:"));
    }

    #[test]
    fn keeps_normal_output() {
        let input = "file.rs:10: println!(\"hello\")";
        let out = sanitize_tool_output(input, 1024);
        assert_eq!(out.redacted_blobs, 0);
        assert_eq!(out.content, input);
    }

    #[test]
    fn truncates_after_sanitization() {
        let input = "hello ".repeat(200);
        let out = sanitize_tool_output(&input, 100);
        assert!(out.truncated);
        assert!(out.content.contains("[output truncated at 100 bytes]"));
    }
}
