# Channel Gateway — Adapter Migration Progress

## Status: MILESTONE COMPLETE

All 3 phases completed. 1247 tests, 0 failures, 0 build warnings.

## Phase 2.1 — Migrate iMessageAdapter (DONE)
- Converted from `actor` to `final class: ChannelAdapter, @unchecked Sendable`
- Added `AdapterState` internal class for thread-safe state without NSLock-in-async warnings
- Added `kind: .imessage` and `onMessage` callback for ChannelGateway integration
- Added `send(response:to:)` delegating to existing `sendReply(text:to:)` AppleScript logic
- Poll loop produces `ChannelMessage` envelopes when `onMessage` is set (gateway path)
- Falls back to legacy `LegacyMessageHandler` for backward compatibility with ChannelManager
- Made `appleMessageDateToDate()` and date conversion `static` for testability
- 8 new tests

## Phase 2.2 — Migrate DiscordAdapter (DONE)
- Converted from `actor` to `final class: ChannelAdapter, @unchecked Sendable`
- Added `AdapterState` internal class with fine-grained lock methods (markStarted, fullStop, teardownForReconnect, markReady, etc.)
- Added `kind: .discord` and `onMessage` callback for ChannelGateway integration
- Added `send(response:to:)` using `message.threadId` as Discord channelId
- `handleMessageCreate` produces `ChannelMessage` envelopes with `threadId = channelId` and `senderDisplayName = username`
- Falls back to legacy `LegacyMessageHandler` for backward compatibility with ChannelManager
- Full WebSocket lifecycle preserved: heartbeat, resume, reconnect with exponential backoff
- 8 new tests

## Phase 2.3 — Migrate WhatsAppAdapter (DONE)
- Converted from `actor` to `final class: ChannelAdapter, @unchecked Sendable`
- Added `ListenerState` internal class for thread-safe NWListener state
- Added `kind: .whatsapp` and `onMessage` callback for ChannelGateway integration
- Added `send(response:to:)` delegating to existing `sendText(to:text:)` Graph API logic
- Parameterless `start()` uses `config.webhookPort` (added to Config struct)
- Webhook handler produces `ChannelMessage` envelopes with message ID from WhatsApp when available
- Falls back to legacy `LegacyMessageHandler` for backward compatibility with ChannelManager
- HMAC-SHA256 verification and NWListener HTTP server fully preserved
- 8 new tests

## Gateway Registration Tests (DONE)
- All three adapters register correctly with ChannelGateway
- Gateway wires `onMessage` callback on registration
- Gateway replaces adapter of same kind
- 8 new tests

## ChannelManager Backward Compatibility
- ChannelManager updated to use `try await adapter.start()` for all adapters
- Legacy handler paths preserved for ChannelManager callers
- No changes needed in FaeCore — ChannelManager still works as before
