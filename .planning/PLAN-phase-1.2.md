# Phase 1.2: Message Pipeline Bridge

## Overview
Create `src/canvas/bridge.rs` that subscribes to `RuntimeEvent` broadcasts and
routes them to `CanvasSession`, converting pipeline events into canvas messages.
Add message grouping, timestamps, scroll-viewport tracking, and barge-in handling.

---

## Task 1: Create `src/canvas/bridge.rs` with CanvasBridge struct

**Description**: CanvasBridge owns a CanvasSession and provides `on_event()` to
route RuntimeEvents to canvas messages.

**Files to create**: `src/canvas/bridge.rs`
**Files to modify**: `src/canvas/mod.rs`

**Types**:
```rust
pub struct CanvasBridge {
    session: CanvasSession,
    /// Accumulates assistant sentence chunks into a single message.
    pending_assistant_text: String,
    /// Whether assistant is currently generating.
    generating: bool,
    /// Last message role for grouping.
    last_role: Option<MessageRole>,
}
```

**Methods**:
- `new(session_id, width, height) -> Self`
- `session(&self) -> &CanvasSession`
- `on_event(&mut self, event: &RuntimeEvent)` — routes events

**Tests**: Construction, session access.

---

## Task 2: Map RuntimeEvent::Transcription to user messages

**Description**: When a final transcription arrives, push a User message.

**Implementation** in `on_event()`:
- `RuntimeEvent::Transcription(t)` where `t.is_final` → push User message
- Use `std::time::Instant` elapsed as rough timestamp

**Tests**: Final transcription creates user message, partial transcription ignored.

---

## Task 3: Map RuntimeEvent::AssistantSentence to assistant messages

**Description**: Accumulate sentence chunks. On `is_final`, flush the accumulated
text as a single Assistant message.

**Implementation**:
- `AssistantSentence(chunk)` → append to `pending_assistant_text`
- When `chunk.is_final` → push accumulated text as Assistant message, clear buffer

**Tests**: Single sentence, multi-chunk accumulation, final flushes.

---

## Task 4: Map RuntimeEvent::ToolCall/ToolResult to tool messages

**Description**: Tool calls and results become Tool role messages.

**Implementation**:
- `ToolCall { name, input_json }` → push Tool message "[name] called"
- `ToolResult { name, success }` → push Tool message "[name] → success/failed"

**Tests**: Tool call message, tool result success/failure formatting.

---

## Task 5: Add message grouping (consecutive same-role messages)

**Description**: Track `last_role`. When same role pushes again consecutively,
update the message count metadata (for future "N messages" indicator).

**Implementation**:
- Track `last_role: Option<MessageRole>` and `group_count: usize`
- Reset count when role changes

**Tests**: Same-role consecutive, role switch resets.

---

## Task 6: Add timestamp rendering

**Description**: Messages get formatted timestamps. Add `formatted_timestamp()`
helper that produces "HH:MM" from epoch ms.

**Files to modify**: `src/canvas/types.rs`

**Implementation**:
- `CanvasMessage::formatted_time(&self) -> String`

**Tests**: Formatting, zero timestamp.

---

## Task 7: Handle barge-in / cancellation visual indication

**Description**: When `ControlEvent::UserSpeechStart` arrives while assistant is
generating, mark a "cancelled" system message.

**Implementation**:
- Track `generating` flag from `AssistantGenerating` events
- On `UserSpeechStart` while `generating` → push System "interrupted"
- Flush any pending assistant text with "[interrupted]" suffix

**Tests**: Barge-in during generation, no barge-in when idle.

---

## Task 8: Integration tests — full event routing

**Description**: Comprehensive tests for the complete bridge.

**Test cases**:
1. Full conversation: transcription → assistant response → verify 2 messages
2. Multi-sentence response: 3 chunks + final → single assistant message
3. Tool call + result: verify both messages appear
4. Barge-in: user speaks during generation → interrupted message
5. Message ordering: events in order produce messages in order
6. Empty session HTML: bridge with no events → valid HTML

**Verification**: `just test` passes, `just lint` zero warnings.
