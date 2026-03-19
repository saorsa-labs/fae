# Plan: Phase 1.1 — ChannelMessage Envelope + ChannelSession Actor

## Context
Create normalised message types that all channel adapters will use, plus per-sender conversation state management.

---

## Task 1: Create ChannelMessage.swift

**File:** `native/macos/Fae/Sources/Fae/Channels/ChannelMessage.swift`

**What:** Define `ChannelKind` enum, `ChannelAttachment` struct, and `ChannelMessage` struct.

- `ChannelKind`: `.imessage`, `.whatsapp`, `.discord` with String rawValues
- `ChannelAttachment`: placeholder with `type`, `url`, `data`, `mimeType`
- `ChannelMessage`: normalised envelope with `id`, `channel`, `senderId`, `senderDisplayName`, `text`, `timestamp`, `threadId`, `replyToId`, `attachments`
- All types must be `Sendable`

---

## Task 2: Create ChannelSession.swift

**File:** `native/macos/Fae/Sources/Fae/Channels/ChannelSession.swift`

**What:** Define `SessionKey` and `ChannelSession` for per-sender conversation state.

- `SessionKey`: struct with `channel: ChannelKind` + `senderId: String`, Hashable
- `ChannelSession`: holds `key`, `messages: [LLMMessage]`, `lastActivity`, `senderDisplayName`, `isActive`
- Methods: `addUserMessage(_:)`, `addAssistantMessage(_:)`, `trimHistory(maxMessages:)`

---

## Task 3: Create ChannelSessionStore.swift

**File:** `native/macos/Fae/Sources/Fae/Channels/ChannelSessionStore.swift`

**What:** Actor managing all channel sessions.

- `session(for: SessionKey) -> ChannelSession` — creates on first access
- `cleanupIdle(olderThan: TimeInterval)` — removes stale sessions
- `activeSessionCount: Int`

---

## Task 4: Create unit tests

**File:** `native/macos/Fae/Tests/HandoffTests/ChannelGatewayTests.swift`

**What:** Tests for ChannelMessage, ChannelSession, ChannelSessionStore.

---

## Task 5: Build & verify

- `swift build` — zero warnings
- `swift test` — zero failures
