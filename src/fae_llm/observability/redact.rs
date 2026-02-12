/// Secret redaction utilities for preventing credential leaks in logs.
///
/// This module provides types and functions for safely handling sensitive data
/// in logging, error messages, and debugging output.
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::redact::RedactedString;
///
/// let api_key = RedactedString::new("sk-1234567890abcdef");
/// println!("API Key: {}", api_key); // Prints: API Key: [REDACTED]
/// ```
use std::fmt;

/// A string wrapper that redacts its value in Display and Debug output.
///
/// This type is used to wrap sensitive data (API keys, tokens, passwords) to prevent
/// accidental leakage in logs, error messages, or debug output.
///
/// # Security Guarantee
///
/// The wrapped value is **never** exposed through [`Display`] or [`Debug`]. The only
/// way to access the inner value is through explicit methods like [`as_str`](RedactedString::as_str).
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::redact::RedactedString;
///
/// let secret = RedactedString::new("sk-my-secret-api-key");
///
/// // Display and Debug show "[REDACTED]"
/// assert_eq!(format!("{}", secret), "[REDACTED]");
/// assert_eq!(format!("{:?}", secret), "RedactedString(\"[REDACTED]\")");
///
/// // Explicit access is still possible when needed
/// assert_eq!(secret.as_str(), "sk-my-secret-api-key");
/// ```
#[derive(Clone)]
pub struct RedactedString {
    inner: String,
}

impl RedactedString {
    /// Create a new redacted string.
    pub fn new<S: Into<String>>(value: S) -> Self {
        Self {
            inner: value.into(),
        }
    }

    /// Access the inner value (use sparingly and only when necessary).
    ///
    /// This method should only be called when the actual value is needed
    /// (e.g., for sending in HTTP headers). Avoid using this in contexts
    /// where the value might be logged or displayed.
    pub fn as_str(&self) -> &str {
        &self.inner
    }

    /// Consume the RedactedString and return the inner value.
    pub fn into_inner(self) -> String {
        self.inner
    }
}

impl fmt::Display for RedactedString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[REDACTED]")
    }
}

impl fmt::Debug for RedactedString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "RedactedString(\"[REDACTED]\")")
    }
}

/// Redact API keys starting with "sk-" prefix (OpenAI, Anthropic).
///
/// Replaces any occurrence of "sk-" followed by alphanumeric characters with "sk-***REDACTED***".
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::redact::redact_api_key;
///
/// let text = "Using key: sk-1234567890abcdefghijklmnopqrstuv";
/// assert!(redact_api_key(text).contains("sk-***REDACTED***"));
/// assert!(!redact_api_key(text).contains("1234567890"));
/// ```
pub fn redact_api_key(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();

    while let Some(c) = chars.next() {
        if c == 's' {
            // Look for "sk-" pattern
            let next1 = chars.peek().copied();
            if next1 == Some('k') {
                chars.next(); // consume 'k'
                let next2 = chars.peek().copied();
                if next2 == Some('-') {
                    chars.next(); // consume '-'
                    // Skip alphanumeric and underscore/dash until whitespace or end
                    while let Some(&nc) = chars.peek() {
                        if nc.is_alphanumeric() || nc == '_' || nc == '-' {
                            chars.next();
                        } else {
                            break;
                        }
                    }
                    result.push_str("sk-***REDACTED***");
                    continue;
                }
                result.push('s');
                result.push('k');
                continue;
            }
        }
        result.push(c);
    }

    result
}

/// Redact Authorization Bearer tokens in HTTP headers.
///
/// Replaces `Authorization: Bearer TOKEN` with `Authorization: Bearer ***REDACTED***`.
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::redact::redact_auth_header;
///
/// let header = "Authorization: Bearer abc123def456";
/// assert_eq!(redact_auth_header(header), "Authorization: Bearer ***REDACTED***");
/// ```
pub fn redact_auth_header(s: &str) -> String {
    // Simple pattern: find "Bearer " and redact everything after it until newline/end
    if let Some(pos) = s.to_lowercase().find("bearer ") {
        let before = &s[..pos + 7]; // Include "Bearer "
        let after = &s[pos + 7..];

        // Find the end of the token (whitespace or end of string)
        let token_end = after
            .find(|c: char| c.is_whitespace())
            .unwrap_or(after.len());
        let rest = &after[token_end..];

        format!("{}***REDACTED***{}", before, rest)
    } else {
        s.to_string()
    }
}

/// Redact API keys in JSON-like strings.
///
/// Replaces values in `"api_key": "VALUE"` patterns with `"***REDACTED***"`.
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::redact::redact_api_key_in_json;
///
/// let json = r#"{"api_key": "secret123", "model": "gpt-4"}"#;
/// let redacted = redact_api_key_in_json(json);
/// assert!(redacted.contains(r#""api_key": "***REDACTED***""#));
/// assert!(redacted.contains(r#""model": "gpt-4""#));
/// ```
pub fn redact_api_key_in_json(s: &str) -> String {
    // Look for "api_key": "..." pattern
    if let Some(pos) = s.find("\"api_key\"") {
        let before = &s[..pos];
        let after = &s[pos..];

        // Find the colon
        if let Some(colon_pos) = after.find(':') {
            let after_colon = &after[colon_pos + 1..];

            // Find the opening quote
            if let Some(quote_start) = after_colon.find('"') {
                let after_quote = &after_colon[quote_start + 1..];

                // Find the closing quote
                if let Some(quote_end) = after_quote.find('"') {
                    let rest = &after_quote[quote_end + 1..]; // +1 to skip the closing quote
                    return format!("{}\"api_key\": \"***REDACTED***\"{}", before, rest);
                }
            }
        }
    }

    s.to_string()
}

/// Redact all known secret patterns in a string.
///
/// This is a convenience function that applies all redaction patterns:
/// - API keys (sk- prefix)
/// - Authorization headers
/// - Generic API keys in JSON
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::redact::redact_all;
///
/// let text = "Using sk-1234567890abcdefghijklmnopqrstuv with Authorization: Bearer token123";
/// let redacted = redact_all(text);
/// assert!(redacted.contains("sk-***REDACTED***"));
/// assert!(redacted.contains("Bearer ***REDACTED***"));
/// ```
pub fn redact_all(s: &str) -> String {
    let s = redact_api_key(s);
    let s = redact_auth_header(&s);
    redact_api_key_in_json(&s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacted_string_never_leaks_in_display() {
        let secret = RedactedString::new("my-secret-password");
        assert_eq!(format!("{}", secret), "[REDACTED]");
        assert_eq!(format!("{:?}", secret), "RedactedString(\"[REDACTED]\")");
    }

    #[test]
    fn redacted_string_explicit_access() {
        let secret = RedactedString::new("actual-value");
        assert_eq!(secret.as_str(), "actual-value");
        assert_eq!(secret.clone().into_inner(), "actual-value");
    }

    #[test]
    fn redact_openai_keys() {
        let text = "My key is sk-1234567890abcdefghijklmnopqrstuv";
        let redacted = redact_api_key(text);
        assert_eq!(redacted, "My key is sk-***REDACTED***");
        assert!(!redacted.contains("1234567890"));
    }

    #[test]
    fn redact_anthropic_keys() {
        let key = format!("sk-ant-api03-{}", "x".repeat(88));
        let text = format!("Using key: {}", key);
        let redacted = redact_api_key(&text);
        assert!(redacted.contains("sk-***REDACTED***"));
        assert!(!redacted.contains("xxxxxxxx"));
    }

    #[test]
    fn redact_bearer_tokens() {
        let header = "Authorization: Bearer abc123def456ghi789";
        let redacted = redact_auth_header(header);
        assert_eq!(redacted, "Authorization: Bearer ***REDACTED***");
        assert!(!redacted.contains("abc123"));
    }

    #[test]
    fn redact_bearer_tokens_case_insensitive() {
        let header = "authorization: bearer TOKEN";
        let redacted = redact_auth_header(header);
        assert!(redacted.contains("***REDACTED***"));
    }

    #[test]
    fn redact_json_api_keys() {
        let json = r#"{"api_key": "secret123", "model": "gpt-4"}"#;
        let redacted = redact_api_key_in_json(json);
        assert!(redacted.contains(r#""api_key": "***REDACTED***""#));
        assert!(redacted.contains(r#""model": "gpt-4""#));
        assert!(!redacted.contains("secret123"));
    }

    #[test]
    fn redact_all_patterns() {
        let text = concat!(
            "Config: {\"api_key\": \"test\"}\n",
            "OpenAI: sk-1234567890abcdefghijklmnopqrstuv\n",
            "Header: Authorization: Bearer token123"
        );
        let redacted = redact_all(text);

        assert!(redacted.contains(r#""api_key": "***REDACTED***""#));
        assert!(redacted.contains("sk-***REDACTED***"));
        assert!(redacted.contains("Bearer ***REDACTED***"));

        assert!(!redacted.contains("test"));
        assert!(!redacted.contains("1234567890"));
        assert!(!redacted.contains("token123"));
    }

    #[test]
    fn redaction_preserves_non_secrets() {
        let text = "model=gpt-4 temperature=0.7";
        let redacted = redact_all(text);
        assert_eq!(redacted, text); // No secrets, unchanged
    }
}
