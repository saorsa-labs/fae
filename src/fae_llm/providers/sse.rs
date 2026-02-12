//! Server-Sent Events (SSE) parser for LLM streaming responses.
//!
//! Implements a reusable SSE parser that converts a byte stream into
//! structured [`SseEvent`]s. Handles multi-line `data:` fields,
//! event types, comment lines, and the `[DONE]` sentinel.
//!
//! # SSE Format
//!
//! ```text
//! event: message
//! data: {"key": "value"}
//!
//! data: {"next": "chunk"}
//!
//! data: [DONE]
//! ```
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::providers::sse::SseEvent;
//!
//! let event = SseEvent {
//!     event_type: Some("message".into()),
//!     data: r#"{"text":"hello"}"#.into(),
//!     id: None,
//! };
//! assert_eq!(event.event_type.as_deref(), Some("message"));
//! ```

/// A parsed Server-Sent Event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    /// The event type (from `event:` field). `None` if not specified.
    pub event_type: Option<String>,
    /// The data payload (from `data:` field(s)). Multiple data lines are joined with `\n`.
    pub data: String,
    /// The event ID (from `id:` field). `None` if not specified.
    pub id: Option<String>,
}

impl SseEvent {
    /// Whether this event is the `[DONE]` sentinel.
    pub fn is_done(&self) -> bool {
        self.data.trim() == "[DONE]"
    }
}

/// Internal state for building an SSE event from lines.
#[derive(Debug, Default)]
struct EventBuilder {
    event_type: Option<String>,
    data_lines: Vec<String>,
    id: Option<String>,
}

impl EventBuilder {
    /// Whether we have any data to emit.
    fn has_data(&self) -> bool {
        !self.data_lines.is_empty()
    }

    /// Build the event and reset state.
    fn build(&mut self) -> SseEvent {
        let event = SseEvent {
            event_type: self.event_type.take(),
            data: self.data_lines.join("\n"),
            id: self.id.take(),
        };
        self.data_lines.clear();
        event
    }

    /// Process a single line of SSE input.
    ///
    /// Returns `Some(SseEvent)` when an empty line (event boundary) is encountered
    /// and there is accumulated data.
    fn process_line(&mut self, line: &str) -> Option<SseEvent> {
        // Empty line = event boundary
        if line.is_empty() {
            if self.has_data() {
                return Some(self.build());
            }
            return None;
        }

        // Comment line (starts with ':')
        if line.starts_with(':') {
            return None;
        }

        // Parse field:value
        if let Some((field, value)) = parse_field(line) {
            match field {
                "data" => self.data_lines.push(value.to_string()),
                "event" => self.event_type = Some(value.to_string()),
                "id" => self.id = Some(value.to_string()),
                // Ignore unknown fields per SSE spec
                _ => {}
            }
        }

        None
    }
}

/// Parse a line into (field, value). The value has leading space stripped.
fn parse_field(line: &str) -> Option<(&str, &str)> {
    let colon_pos = line.find(':')?;
    let field = &line[..colon_pos];
    let mut value = &line[colon_pos + 1..];
    // Strip single leading space after colon per SSE spec
    if value.starts_with(' ') {
        value = &value[1..];
    }
    Some((field, value))
}

/// Parse raw SSE text into a vector of events.
///
/// This is the primary entry point for parsing SSE data received as a
/// complete string (e.g. from a buffered response). For streaming use,
/// create an [`SseLineParser`] and feed lines incrementally.
///
/// # Examples
///
/// ```
/// use fae::fae_llm::providers::sse::parse_sse_text;
///
/// let input = "data: hello\n\ndata: world\n\n";
/// let events = parse_sse_text(input);
/// assert_eq!(events.len(), 2);
/// assert_eq!(events[0].data, "hello");
/// assert_eq!(events[1].data, "world");
/// ```
pub fn parse_sse_text(text: &str) -> Vec<SseEvent> {
    let mut builder = EventBuilder::default();
    let mut events = Vec::new();

    for line in text.lines() {
        if let Some(event) = builder.process_line(line) {
            events.push(event);
        }
    }

    // Flush any trailing event (data without final empty line)
    if builder.has_data() {
        events.push(builder.build());
    }

    events
}

/// Incrementally parse SSE bytes, yielding events as they become complete.
///
/// Maintains internal line buffer state. Feed chunks of bytes via
/// [`SseLineParser::push`] and collect emitted events.
#[derive(Debug, Default)]
pub struct SseLineParser {
    line_buffer: String,
    builder: EventBuilder,
}

impl SseLineParser {
    /// Create a new incremental SSE parser.
    pub fn new() -> Self {
        Self::default()
    }

    /// Push a chunk of bytes into the parser.
    ///
    /// Returns any complete events that were parsed from this chunk.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<SseEvent> {
        let text = String::from_utf8_lossy(chunk);
        let mut events = Vec::new();

        for ch in text.chars() {
            if ch == '\n' {
                let line = std::mem::take(&mut self.line_buffer);
                // Handle \r\n by stripping trailing \r
                let line = line.strip_suffix('\r').unwrap_or(&line);
                if let Some(event) = self.builder.process_line(line) {
                    events.push(event);
                }
            } else {
                self.line_buffer.push(ch);
            }
        }

        events
    }

    /// Flush any remaining buffered data as a final event.
    ///
    /// Call this when the stream ends to emit any incomplete event.
    pub fn flush(&mut self) -> Option<SseEvent> {
        // Process any remaining line in the buffer
        if !self.line_buffer.is_empty() {
            let line = std::mem::take(&mut self.line_buffer);
            let line = line.strip_suffix('\r').unwrap_or(&line);
            self.builder.process_line(line);
        }

        if self.builder.has_data() {
            Some(self.builder.build())
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_field ───────────────────────────────────────────

    #[test]
    fn parse_field_basic() {
        let result = parse_field("data: hello");
        assert_eq!(result, Some(("data", "hello")));
    }

    #[test]
    fn parse_field_no_space_after_colon() {
        let result = parse_field("data:hello");
        assert_eq!(result, Some(("data", "hello")));
    }

    #[test]
    fn parse_field_empty_value() {
        let result = parse_field("data:");
        assert_eq!(result, Some(("data", "")));
    }

    #[test]
    fn parse_field_with_colons_in_value() {
        let result = parse_field("data: {\"key\":\"value\"}");
        assert_eq!(result, Some(("data", "{\"key\":\"value\"}")));
    }

    #[test]
    fn parse_field_no_colon() {
        let result = parse_field("nodatahere");
        assert!(result.is_none());
    }

    // ── SseEvent ──────────────────────────────────────────────

    #[test]
    fn sse_event_is_done() {
        let event = SseEvent {
            event_type: None,
            data: "[DONE]".into(),
            id: None,
        };
        assert!(event.is_done());
    }

    #[test]
    fn sse_event_is_done_with_whitespace() {
        let event = SseEvent {
            event_type: None,
            data: " [DONE] ".into(),
            id: None,
        };
        assert!(event.is_done());
    }

    #[test]
    fn sse_event_not_done() {
        let event = SseEvent {
            event_type: None,
            data: "{\"text\":\"hello\"}".into(),
            id: None,
        };
        assert!(!event.is_done());
    }

    #[test]
    fn sse_event_clone() {
        let event = SseEvent {
            event_type: Some("message".into()),
            data: "test".into(),
            id: Some("1".into()),
        };
        let cloned = event.clone();
        assert_eq!(event, cloned);
    }

    // ── parse_sse_text ────────────────────────────────────────

    #[test]
    fn parse_single_event() {
        let input = "data: hello\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "hello");
        assert!(events[0].event_type.is_none());
        assert!(events[0].id.is_none());
    }

    #[test]
    fn parse_multiple_events() {
        let input = "data: first\n\ndata: second\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].data, "first");
        assert_eq!(events[1].data, "second");
    }

    #[test]
    fn parse_event_with_type() {
        let input = "event: message\ndata: hello\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type.as_deref(), Some("message"));
        assert_eq!(events[0].data, "hello");
    }

    #[test]
    fn parse_event_with_id() {
        let input = "id: 42\ndata: hello\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id.as_deref(), Some("42"));
    }

    #[test]
    fn parse_multi_line_data() {
        let input = "data: line1\ndata: line2\ndata: line3\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "line1\nline2\nline3");
    }

    #[test]
    fn parse_comments_ignored() {
        let input = ": this is a comment\ndata: hello\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "hello");
    }

    #[test]
    fn parse_done_sentinel() {
        let input = "data: {\"text\":\"hello\"}\n\ndata: [DONE]\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 2);
        assert!(!events[0].is_done());
        assert!(events[1].is_done());
    }

    #[test]
    fn parse_empty_lines_between_events() {
        let input = "\n\ndata: hello\n\n\n\ndata: world\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn parse_empty_input() {
        let events = parse_sse_text("");
        assert!(events.is_empty());
    }

    #[test]
    fn parse_comments_only() {
        let events = parse_sse_text(": comment1\n: comment2\n\n");
        assert!(events.is_empty());
    }

    #[test]
    fn parse_trailing_event_without_empty_line() {
        let input = "data: hello";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "hello");
    }

    #[test]
    fn parse_json_data() {
        let input = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0].data,
            "{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"
        );
    }

    #[test]
    fn parse_unknown_fields_ignored() {
        let input = "retry: 5000\ndata: hello\n\n";
        let events = parse_sse_text(input);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "hello");
    }

    // ── SseLineParser (incremental) ───────────────────────────

    #[test]
    fn incremental_single_chunk() {
        let mut parser = SseLineParser::new();
        let events = parser.push(b"data: hello\n\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "hello");
    }

    #[test]
    fn incremental_split_across_chunks() {
        let mut parser = SseLineParser::new();

        let events1 = parser.push(b"data: hel");
        assert!(events1.is_empty());

        let events2 = parser.push(b"lo\n\n");
        assert_eq!(events2.len(), 1);
        assert_eq!(events2[0].data, "hello");
    }

    #[test]
    fn incremental_multiple_events_across_chunks() {
        let mut parser = SseLineParser::new();

        let events1 = parser.push(b"data: first\n\ndata: sec");
        assert_eq!(events1.len(), 1);
        assert_eq!(events1[0].data, "first");

        let events2 = parser.push(b"ond\n\n");
        assert_eq!(events2.len(), 1);
        assert_eq!(events2[0].data, "second");
    }

    #[test]
    fn incremental_flush_trailing_event() {
        let mut parser = SseLineParser::new();
        let events = parser.push(b"data: trailing");
        assert!(events.is_empty());

        let flushed = parser.flush();
        assert!(flushed.is_some());
        match flushed {
            Some(e) => assert_eq!(e.data, "trailing"),
            None => unreachable!("flush returned Some"),
        }
    }

    #[test]
    fn incremental_flush_empty() {
        let mut parser = SseLineParser::new();
        let flushed = parser.flush();
        assert!(flushed.is_none());
    }

    #[test]
    fn incremental_crlf_handling() {
        let mut parser = SseLineParser::new();
        let events = parser.push(b"data: hello\r\n\r\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "hello");
    }

    #[test]
    fn incremental_event_type_preserved() {
        let mut parser = SseLineParser::new();
        let events = parser.push(b"event: delta\ndata: content\n\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type.as_deref(), Some("delta"));
        assert_eq!(events[0].data, "content");
    }

    #[test]
    fn incremental_done_sentinel() {
        let mut parser = SseLineParser::new();
        let events = parser.push(b"data: [DONE]\n\n");
        assert_eq!(events.len(), 1);
        assert!(events[0].is_done());
    }

    // ── EventBuilder ──────────────────────────────────────────

    #[test]
    fn event_builder_empty_has_no_data() {
        let builder = EventBuilder::default();
        assert!(!builder.has_data());
    }

    #[test]
    fn event_builder_accumulates_data() {
        let mut builder = EventBuilder::default();
        builder.process_line("data: line1");
        assert!(builder.has_data());
        builder.process_line("data: line2");

        let event = builder.process_line("");
        assert!(event.is_some());
        match event {
            Some(e) => assert_eq!(e.data, "line1\nline2"),
            None => unreachable!("event builder emitted event"),
        }
    }

    #[test]
    fn event_builder_resets_after_build() {
        let mut builder = EventBuilder::default();
        builder.process_line("data: test");
        let _event = builder.process_line("");
        assert!(!builder.has_data());
    }

    #[test]
    fn event_builder_comment_has_no_effect() {
        let mut builder = EventBuilder::default();
        let result = builder.process_line(": this is a comment");
        assert!(result.is_none());
        assert!(!builder.has_data());
    }

    #[test]
    fn event_builder_empty_line_without_data() {
        let mut builder = EventBuilder::default();
        let result = builder.process_line("");
        assert!(result.is_none());
    }
}
