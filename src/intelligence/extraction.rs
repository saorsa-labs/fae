//! Extraction response parsing for intelligence items.
//!
//! Parses JSON responses from the LLM extraction prompt into
//! [`ExtractionResult`] values. Handles malformed or partial JSON gracefully.

use crate::intelligence::types::ExtractionResult;
use tracing::warn;

/// Parse an extraction response from the LLM.
///
/// Accepts raw text (which may contain markdown fences or extra whitespace)
/// and attempts to deserialize it into an [`ExtractionResult`].
///
/// Returns an empty result on failure rather than an error, since extraction
/// is best-effort and should never block the conversation pipeline.
#[must_use]
pub fn parse_extraction_response(raw: &str) -> ExtractionResult {
    let json_str = extract_json_block(raw);

    match serde_json::from_str::<ExtractionResult>(json_str) {
        Ok(mut result) => {
            // Clamp item count and validate.
            result.items.retain(|item| item.is_valid());
            if result.items.len() > MAX_ITEMS {
                result.items.truncate(MAX_ITEMS);
            }
            result
        }
        Err(e) => {
            if !json_str.trim().is_empty() {
                warn!("intelligence extraction parse failed: {e}");
            }
            ExtractionResult::default()
        }
    }
}

/// Maximum items to keep from a single extraction pass.
const MAX_ITEMS: usize = 10;

/// Extract the JSON body from a potentially markdown-fenced response.
fn extract_json_block(raw: &str) -> &str {
    let trimmed = raw.trim();

    // Check for ```json ... ``` fences.
    if let Some(start) = trimmed.find("```json") {
        let after_fence = &trimmed[start + 7..];
        if let Some(end) = after_fence.find("```") {
            return after_fence[..end].trim();
        }
    }

    // Check for ``` ... ``` fences (no language tag).
    if let Some(start) = trimmed.find("```") {
        let after_fence = &trimmed[start + 3..];
        if let Some(end) = after_fence.find("```") {
            return after_fence[..end].trim();
        }
    }

    // Try to find JSON object boundaries.
    if let Some(start) = trimmed.find('{')
        && let Some(end) = trimmed.rfind('}')
        && end > start
    {
        return &trimmed[start..=end];
    }

    trimmed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::intelligence::types::IntelligenceKind;

    #[test]
    fn parse_valid_json() {
        let json = r#"{
            "items": [
                {
                    "kind": "date_event",
                    "text": "Birthday March 15",
                    "confidence": 0.95,
                    "metadata": {"date_iso": "2026-03-15", "recurring": true}
                },
                {
                    "kind": "person_mention",
                    "text": "Friend Sarah",
                    "confidence": 0.85,
                    "metadata": {"name": "Sarah", "relationship": "friend"}
                }
            ],
            "actions": [
                {
                    "type": "create_scheduler_task",
                    "name": "birthday_reminder",
                    "trigger_at": "2026-03-14",
                    "prompt": "Tomorrow is the user's birthday"
                }
            ]
        }"#;

        let result = parse_extraction_response(json);
        assert_eq!(result.items.len(), 2);
        assert_eq!(result.actions.len(), 1);
        assert_eq!(result.items[0].kind, IntelligenceKind::DateEvent);
        assert_eq!(result.items[1].kind, IntelligenceKind::PersonMention);
    }

    #[test]
    fn parse_markdown_fenced_json() {
        let raw = r#"Here is the extraction:

```json
{
    "items": [
        {
            "kind": "interest",
            "text": "Hiking",
            "confidence": 0.8
        }
    ],
    "actions": []
}
```

That's all I found."#;

        let result = parse_extraction_response(raw);
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].kind, IntelligenceKind::Interest);
    }

    #[test]
    fn parse_unfenced_json() {
        let raw = r#"Some preamble
{
    "items": [{"kind": "commitment", "text": "Call dentist", "confidence": 0.7}],
    "actions": []
}
trailing text"#;

        let result = parse_extraction_response(raw);
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].kind, IntelligenceKind::Commitment);
    }

    #[test]
    fn parse_empty_result() {
        let json = r#"{"items": [], "actions": []}"#;
        let result = parse_extraction_response(json);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_empty_json_object() {
        let json = "{}";
        let result = parse_extraction_response(json);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_malformed_json_returns_empty() {
        let result = parse_extraction_response("this is not json at all");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_partial_json_returns_empty() {
        let result = parse_extraction_response(r#"{"items": [{"kind": "broken"#);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_filters_invalid_items() {
        let json = r#"{
            "items": [
                {"kind": "interest", "text": "Valid", "confidence": 0.8},
                {"kind": "interest", "text": "  ", "confidence": 0.8},
                {"kind": "interest", "text": "Also valid", "confidence": 0.7}
            ],
            "actions": []
        }"#;

        let result = parse_extraction_response(json);
        // The empty-text item should be filtered out.
        assert_eq!(result.items.len(), 2);
    }

    #[test]
    fn parse_extra_fields_ignored() {
        let json = r#"{
            "items": [
                {"kind": "interest", "text": "Hiking", "confidence": 0.8, "extra_field": true}
            ],
            "actions": [],
            "unexpected": "value"
        }"#;

        let result = parse_extraction_response(json);
        assert_eq!(result.items.len(), 1);
    }

    #[test]
    fn parse_respects_max_items() {
        let items: Vec<String> = (0..15)
            .map(|i| {
                format!(r#"{{"kind": "interest", "text": "Interest {i}", "confidence": 0.8}}"#,)
            })
            .collect();
        let json = format!(r#"{{"items": [{}], "actions": []}}"#, items.join(","));

        let result = parse_extraction_response(&json);
        assert!(result.items.len() <= MAX_ITEMS);
    }

    #[test]
    fn extract_json_block_plain() {
        let input = r#"{"key": "value"}"#;
        assert_eq!(extract_json_block(input), r#"{"key": "value"}"#);
    }

    #[test]
    fn extract_json_block_with_fence() {
        let input = "```json\n{\"key\": \"value\"}\n```";
        assert_eq!(extract_json_block(input), r#"{"key": "value"}"#);
    }

    #[test]
    fn extract_json_block_with_surrounding_text() {
        let input = "Here: {\"a\": 1} end";
        assert_eq!(extract_json_block(input), r#"{"a": 1}"#);
    }
}
