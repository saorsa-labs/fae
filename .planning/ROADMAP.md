# Unified Channel Gateway Roadmap

## Overview

Replace Fae's per-adapter channel system with a single-process multi-channel gateway. One routing layer, normalised message format, per-sender conversation isolation, shared sessions, and race-free concurrency.

**Problems solved:**
- **Integration gap**: Channels don't share context — WhatsApp conversations invisible to Discord. No cross-channel identity.
- **Poor experience**: Confusing setup, messages lost during reconnect, 5s iMessage polling delay.
- **Technical debt**: 3 adapters with no shared types, race conditions in `injectChannelText`, stub Python scripts, false docs about per-sender isolation.

**Success:** Production ready — complete, tested, documented. Per-sender isolation, shared sessions, race-free. Ship it.

## Technical Decisions
- Error Handling: Dedicated `ChannelGatewayError` enum
- Async Model: Swift actor (matching ChannelManager pattern)
- Testing: Unit + Integration + Concurrency stress tests
- Approach: TDD — tests first, then implementation
- Task Size: Smallest possible (~50 lines per task)
- Migration: Strangler fig — new gateway wraps old adapters, migrate one at a time

## Key Architecture

```
External Messages
    │
    ├── iMessage (SQLite poll) ──┐
    ├── Discord (WebSocket) ─────┤── ChannelAdapter protocol
    └── WhatsApp (HTTP webhook) ─┘
                                 │
                        ChannelGateway (actor)
                           │
                           ├── Normalise → ChannelMessage envelope
                           ├── Route → ChannelSession (per-sender)
                           ├── Serialise (no concurrent processTranscription)
                           └── Dispatch → PipelineCoordinator.injectChannelText()
                                 │
                           Return response
                                 │
                        ChannelGateway routes back to adapter
                           │
                           └── Adapter sends response to external platform
```

## Success Criteria
- All channel messages route through ChannelGateway (no direct adapter→pipeline path)
- Per-sender conversation isolation (WhatsApp Alice ≠ Discord Bob)
- Race-free: concurrent messages serialised through gateway actor
- Cross-channel identity: same person recognised across channels
- All 3 adapters migrated to ChannelAdapter protocol
- Channel health monitoring with auto-reconnect
- Full test coverage: unit + integration + concurrency stress
- Documentation accurate (no false claims about isolation)

---

## Milestone 1: Gateway Core

### Phase 1.1: ChannelMessage Envelope + ChannelSession Actor
- **Focus**: Define `ChannelMessage` struct (normalised envelope with channel, sender, text, timestamp, messageId, threadId, attachments). Define `ChannelSession` actor for per-sender conversation state.
- **Deliverables**: `ChannelMessage.swift`, `ChannelSession.swift`, `ChannelSessionStore.swift`
- **Dependencies**: None (pure addition)
- **Estimated Tasks**: 4-5

### Phase 1.2: ChannelGateway Actor
- **Focus**: Create `ChannelGateway` actor that receives normalised messages, resolves sessions, serialises concurrent dispatch, and routes responses back.
- **Deliverables**: `ChannelGateway.swift`, `ChannelAdapter` protocol
- **Dependencies**: Phase 1.1
- **Estimated Tasks**: 4-6

### Phase 1.3: Per-Sender Conversation Isolation
- **Focus**: Replace single `ConversationState` for channels with per-sender isolated conversation histories. Gateway maintains a `[SessionKey: ConversationState]` map.
- **Deliverables**: Changes to `PipelineCoordinator.injectChannelText()`, `ConversationState` factory
- **Dependencies**: Phase 1.2
- **Estimated Tasks**: 3-5

---

## Milestone 2: Adapter Migration

### Phase 2.1: Migrate iMessageAdapter
- **Focus**: Conform `iMessageAdapter` to `ChannelAdapter` protocol. Replace direct messageHandler closure with gateway dispatch.
- **Deliverables**: Updated `iMessageAdapter.swift`, protocol conformance
- **Dependencies**: Phase 1.2
- **Estimated Tasks**: 3-4

### Phase 2.2: Migrate DiscordAdapter
- **Focus**: Conform `DiscordAdapter` to `ChannelAdapter` protocol. Preserve WebSocket lifecycle, gateway-managed reconnect.
- **Deliverables**: Updated `DiscordAdapter.swift`, protocol conformance
- **Dependencies**: Phase 1.2
- **Estimated Tasks**: 3-4

### Phase 2.3: Migrate WhatsAppAdapter
- **Focus**: Conform `WhatsAppAdapter` to `ChannelAdapter` protocol. Preserve HMAC verification, webhook handling.
- **Deliverables**: Updated `WhatsAppAdapter.swift`, protocol conformance
- **Dependencies**: Phase 1.2
- **Estimated Tasks**: 3-4

---

## Milestone 3: Cross-Channel Features

### Phase 3.1: Shared Identity
- **Focus**: Recognise the same person across channels (e.g., phone number in WhatsApp matches iMessage handle). Link sessions.
- **Deliverables**: `ChannelIdentityResolver.swift`, entity graph integration
- **Dependencies**: Phase 2.3 (all adapters migrated)
- **Estimated Tasks**: 3-4

### Phase 3.2: Cross-Channel Context
- **Focus**: Continue a conversation started on WhatsApp from Discord. Shared conversation history for linked identities.
- **Deliverables**: Session linking in `ChannelSessionStore`, history merge
- **Dependencies**: Phase 3.1
- **Estimated Tasks**: 3-4

### Phase 3.3: Channel Health Monitoring + Auto-Reconnect
- **Focus**: Gateway monitors adapter health, auto-reconnects on failure, reports status via FaeEvent. Replace teardown/restart with graceful reconnect.
- **Deliverables**: Health check protocol, reconnect policy, `FaeEvent.channelHealth`
- **Dependencies**: Phase 2.3
- **Estimated Tasks**: 3-4

---

## Milestone 4: Testing & Hardening

### Phase 4.1: Integration Tests
- **Focus**: End-to-end tests: message arrives at adapter → gateway → pipeline → response → adapter
- **Deliverables**: `ChannelGatewayIntegrationTests.swift`
- **Dependencies**: Phase 2.3
- **Estimated Tasks**: 4-5

### Phase 4.2: Concurrency Stress Tests
- **Focus**: Simultaneous messages from multiple channels/senders. Verify no race conditions, no shared state corruption.
- **Deliverables**: `ChannelGatewayConcurrencyTests.swift`
- **Dependencies**: Phase 4.1
- **Estimated Tasks**: 3-4

### Phase 4.3: Documentation + channel-hub Skill Update
- **Focus**: Update CLAUDE.md, channel-hub skill, channel setup docs. Remove false claims. Document the real architecture.
- **Deliverables**: Updated docs, accurate skill content
- **Dependencies**: Phase 4.2
- **Estimated Tasks**: 2-3

---

## Risks & Mitigations
- **iMessage polling latency**: Consider switching to FSEvents file watcher for chat.db changes (sub-second detection vs 5s poll)
- **WhatsApp external port**: Document ngrok/Cloudflare Tunnel setup in channel-whatsapp skill
- **Discord rate limits**: Gateway should respect per-channel rate limits from Discord REST API
- **Memory growth**: Per-sender sessions need cleanup policy (idle timeout, max sessions)
- **Migration risk**: Strangler fig pattern — old adapters wrapped first, replaced incrementally

## Out of Scope
- New channel adapters (Telegram, Slack, Signal) — future work after gateway ships
- Voice messages in channels (currently text-only)
- File/image attachments in channel messages (ChannelMessage has the field but processing deferred)
- BlueBubbles iMessage replacement (architecture change, separate project)
