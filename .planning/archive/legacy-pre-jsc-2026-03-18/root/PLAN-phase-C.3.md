# Phase C.3: Channel UI Enhancement

## Goal
Add GUI controls for managing Discord and WhatsApp channels, viewing message history, adding rate limiting for outbound messages, and providing setup documentation. Users can configure channels, view conversations, and control message flow through the menu bar panel.

## Context
- Channel system exists: `src/channels/` with ChannelAdapter trait, DiscordAdapter, WhatsAppAdapter, gateway
- Config types: `DiscordChannelConfig`, `WhatsAppChannelConfig`, `ChannelsConfig` in `src/config.rs`
- Channel runtime: `start_runtime()` with event broadcasting via `ChannelRuntimeEvent`
- Credential system: `CredentialRef` for secure token storage (Keychain/encrypted fallback)
- Validation: `validate_config()` checks for missing tokens, empty allowlists
- Health checks: `check_health()` async probe for each adapter
- GUI: `src/bin/gui.rs` with existing panels (Settings, Soul, Skills, Memories, Ingestion, Scheduler)
- No rate limiting exists yet
- No message history viewer exists
- No channel-specific setup docs exist

## Tasks

### Task 1: Add rate limiting module for outbound messages
**Files**: `src/channels/rate_limit.rs` (new), `src/channels/mod.rs`

Implement per-channel outbound message rate limiting.
- `RateLimiter` struct with `max_messages_per_minute: u32`, `window: VecDeque<Instant>`
- `try_send()` → `Result<(), RateLimitError>` — checks window, returns time until next allowed
- `ChannelRateLimits` config struct with per-channel limits (default: 20/min Discord, 10/min WhatsApp)
- Add `rate_limits` field to `ChannelsConfig`
- Wire rate limiter into `run_runtime()` — check before each `adapter.send()`
- Log rate-limited messages as `ChannelRuntimeEvent::Warning`
- Tests: burst within limit, burst exceeding limit, window sliding, per-channel isolation

### Task 2: Add message history storage
**Files**: `src/channels/history.rs` (new), `src/channels/mod.rs`

Store channel message history for UI display.
- `ChannelMessage` struct: `id: String`, `channel: String`, `direction: MessageDirection`, `sender: String`, `text: String`, `timestamp: DateTime<Utc>`, `reply_target: String`
- `MessageDirection` enum: `Inbound`, `Outbound`
- `ChannelHistory` struct with `Vec<ChannelMessage>`, `max_messages: usize` (default 500)
- `push()`, `messages_for_channel()`, `all_messages()`, `clear_channel()`
- Wire into `run_runtime()` — record inbound and outbound messages
- Expose via `ChannelRuntimeEvent::MessageRecorded { message: ChannelMessage }`
- Tests: push and retrieve, max capacity eviction, filter by channel, clear

### Task 3: Create channel status panel types
**File**: `src/ui/channel_panel.rs` (new), `src/ui/mod.rs`

Define types and state for channel management UI.
- `ChannelPanelState` struct: `selected_tab: ChannelTab`, `editing_discord: Option<DiscordEditForm>`, `editing_whatsapp: Option<WhatsAppEditForm>`, `show_history: bool`, `error_message: Option<String>`
- `ChannelTab` enum: `Overview`, `Discord`, `WhatsApp`, `History`
- `DiscordEditForm`: `bot_token: String`, `guild_id: String`, `allowed_user_ids: Vec<String>`, `allowed_channel_ids: Vec<String>`
- `WhatsAppEditForm`: `access_token: String`, `phone_number_id: String`, `verify_token: String`, `allowed_numbers: Vec<String>`
- Helper methods: `from_config()`, `to_config()`, `validate()`
- Tests: create forms, round-trip conversion, validation errors

### Task 4: Create channel overview component
**File**: `src/ui/channel_panel.rs`

Render channel status overview with health indicators.
- `render_channel_overview()` function returning HTML string
- Show per-channel status: Connected/Disconnected/Error with color indicators
- Display last message timestamp per channel
- Show rate limit status (messages remaining in window)
- Auto-start toggle (channels.auto_start)
- "Configure" buttons linking to Discord/WhatsApp tabs
- Health check refresh button
- Tests: render with no channels, render with Discord only, render with both, health status display

### Task 5: Create Discord/WhatsApp configuration forms
**File**: `src/ui/channel_panel.rs`

Render add/edit forms for channel credentials.
- Discord form: bot token input (masked), guild ID input, user allowlist (add/remove), channel allowlist (add/remove)
- WhatsApp form: access token input (masked), phone number ID, verify token (masked), allowed numbers (add/remove)
- "Save" persists to config via `save_config()` and triggers `UiBusEvent::ConfigReloaded`
- "Test Connection" button triggers `check_health()` and shows result
- Inline validation: token not empty, phone number E.164 format
- Setup instructions link/collapsible section for each channel
- Tests: render empty form, render with existing config, save triggers config write, validation

### Task 6: Create message history viewer
**File**: `src/ui/channel_panel.rs`

Render unified message history with channel filtering.
- `render_message_history()` function
- Channel filter tabs: All, Discord, WhatsApp
- Messages displayed in reverse chronological order
- Inbound messages left-aligned (gray), outbound right-aligned (blue)
- Sender name, timestamp, and channel badge per message
- Message text with basic formatting (line breaks preserved)
- Empty state: "No messages yet" with channel status hint
- "Clear History" button per channel
- Tests: render empty history, render messages, filter by channel, direction styling

### Task 7: Wire channel panel into GUI
**File**: `src/bin/gui.rs`

Integrate channel panel into main app window.
- Add `FAE_MENU_OPEN_CHANNELS` constant and menu item "Channels..." in app submenu
- Add `show_channels_panel: Signal<bool>` to app state
- Render channel panel when signal is true (modal overlay matching scheduler panel pattern)
- Subscribe to `ChannelRuntimeEvent` messages to update panel state
- Handle tab navigation, form saves, health checks, history display
- Refresh channel status on panel open
- Tests: panel open/close, menu item triggers signal, config save integration

### Task 8: Add setup documentation and integration tests
**Files**: `src/ui/channel_panel.rs`, `Prompts/system_prompt.md`, `docs/channels-setup.md` (new)

Documentation and full workflow validation.
- Create `docs/channels-setup.md` with:
  - Discord bot setup guide (Developer Portal, bot token, intents, guild invite)
  - WhatsApp Business API setup (Meta for Developers, app creation, phone number, webhook)
  - Rate limiting explanation and customization
  - Troubleshooting common issues
- Update system prompt: mention Channels panel for GUI users
- Integration test: open panel → configure Discord → save → verify config persisted → view history → clear
- Test edge cases: invalid tokens, rate limit exceeded display, health check failure
- Tests: end-to-end workflow, documentation references valid
