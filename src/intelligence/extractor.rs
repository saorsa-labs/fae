//! Intelligence extractor that drives LLM-based extraction.
//!
//! After each conversation turn, the extractor sends the user and assistant
//! text to the LLM with a specialized extraction prompt, then parses the
//! response into [`ExtractionResult`] items and actions.

use crate::intelligence::extraction::parse_extraction_response;
use crate::intelligence::types::ExtractionResult;

/// The extraction system prompt (loaded from `Prompts/extraction.md` at compile time).
const EXTRACTION_PROMPT: &str = include_str!("../../Prompts/extraction.md");

/// Orchestrates intelligence extraction from conversation turns.
///
/// Uses the configured LLM to analyze conversation text and extract
/// actionable intelligence items. The extraction is designed to run
/// asynchronously after each turn without blocking the conversation.
#[derive(Debug, Clone)]
pub struct IntelligenceExtractor {
    /// Maximum tokens for the extraction response.
    max_tokens: usize,
}

impl IntelligenceExtractor {
    /// Create a new extractor with default settings.
    pub fn new() -> Self {
        Self { max_tokens: 1024 }
    }

    /// Set the maximum token budget for extraction responses.
    #[must_use]
    pub fn with_max_tokens(mut self, max_tokens: usize) -> Self {
        self.max_tokens = max_tokens;
        self
    }

    /// Returns the maximum token budget.
    #[must_use]
    pub fn max_tokens(&self) -> usize {
        self.max_tokens
    }

    /// Build the extraction prompt for a conversation turn.
    ///
    /// Returns `(system_prompt, user_prompt)` for the LLM call.
    #[must_use]
    pub fn build_extraction_prompt(
        &self,
        user_text: &str,
        assistant_text: &str,
        memory_context: Option<&str>,
    ) -> (String, String) {
        let system = EXTRACTION_PROMPT.to_owned();

        let mut user_prompt = String::new();
        user_prompt.push_str("## Conversation Turn\n\n");
        user_prompt.push_str(&format!("**User:** {user_text}\n\n"));
        user_prompt.push_str(&format!("**Assistant:** {assistant_text}\n\n"));

        if let Some(ctx) = memory_context {
            user_prompt.push_str("## Existing Memory Context\n\n");
            user_prompt.push_str(ctx);
            user_prompt.push_str("\n\n");
        }

        user_prompt.push_str("Extract intelligence items and actions from this conversation turn.");

        (system, user_prompt)
    }

    /// Parse a raw LLM response into an extraction result.
    ///
    /// This is the synchronous parsing step. The actual LLM call is handled
    /// by the caller (typically the pipeline coordinator) using whatever
    /// provider is configured.
    #[must_use]
    pub fn parse_response(&self, raw_response: &str) -> ExtractionResult {
        parse_extraction_response(raw_response)
    }
}

impl Default for IntelligenceExtractor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extractor_default_max_tokens() {
        let extractor = IntelligenceExtractor::new();
        assert_eq!(extractor.max_tokens(), 1024);
    }

    #[test]
    fn extractor_custom_max_tokens() {
        let extractor = IntelligenceExtractor::new().with_max_tokens(2048);
        assert_eq!(extractor.max_tokens(), 2048);
    }

    #[test]
    fn build_extraction_prompt_without_memory() {
        let extractor = IntelligenceExtractor::new();
        let (system, user) =
            extractor.build_extraction_prompt("my birthday is March 15", "Happy birthday!", None);

        assert!(!system.is_empty());
        assert!(system.contains("intelligence extraction"));
        assert!(user.contains("my birthday is March 15"));
        assert!(user.contains("Happy birthday!"));
        assert!(!user.contains("Memory Context"));
    }

    #[test]
    fn build_extraction_prompt_with_memory() {
        let extractor = IntelligenceExtractor::new();
        let (_, user) = extractor.build_extraction_prompt(
            "hi",
            "hello",
            Some("User's name is David. Lives in Edinburgh."),
        );

        assert!(user.contains("Memory Context"));
        assert!(user.contains("David"));
        assert!(user.contains("Edinburgh"));
    }

    #[test]
    fn parse_response_delegates_to_extraction() {
        let extractor = IntelligenceExtractor::new();
        let json = r#"{"items": [{"kind": "interest", "text": "Hiking", "confidence": 0.8}], "actions": []}"#;
        let result = extractor.parse_response(json);
        assert_eq!(result.items.len(), 1);
    }

    #[test]
    fn parse_response_handles_empty() {
        let extractor = IntelligenceExtractor::new();
        let result = extractor.parse_response("");
        assert!(result.is_empty());
    }

    #[test]
    fn extraction_prompt_loaded() {
        // Verify the compile-time include works.
        assert!(!EXTRACTION_PROMPT.is_empty());
        assert!(EXTRACTION_PROMPT.contains("intelligence extraction"));
    }
}
