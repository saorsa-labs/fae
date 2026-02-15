//! Channel management UI panel types and state.
//!
//! Provides types for managing the channel UI panel, including editing
//! Discord and WhatsApp configurations, viewing message history, and
//! monitoring channel health.

use crate::channels::history::{ChannelMessage, MessageDirection};
use crate::config::{DiscordChannelConfig, WhatsAppChannelConfig};
use crate::credentials::CredentialRef;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// State for the channel management panel.
#[derive(Debug, Clone, Default)]
pub struct ChannelPanelState {
    /// Currently selected tab.
    pub selected_tab: ChannelTab,
    /// Discord configuration being edited (if any).
    pub editing_discord: Option<DiscordEditForm>,
    /// WhatsApp configuration being edited (if any).
    pub editing_whatsapp: Option<WhatsAppEditForm>,
    /// Whether message history view is visible.
    pub show_history: bool,
    /// Error message to display (if any).
    pub error_message: Option<String>,
}

/// Channel panel tabs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelTab {
    /// Overview of all channels with health status.
    #[default]
    Overview,
    /// Discord configuration form.
    Discord,
    /// WhatsApp configuration form.
    WhatsApp,
    /// Message history viewer.
    History,
}

/// Discord configuration edit form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscordEditForm {
    /// Bot token (plaintext for editing).
    pub bot_token: String,
    /// Guild ID filter (optional).
    pub guild_id: String,
    /// Allowed user IDs (one per line for UI).
    pub allowed_user_ids: Vec<String>,
    /// Allowed channel IDs (one per line for UI).
    pub allowed_channel_ids: Vec<String>,
}

impl DiscordEditForm {
    /// Create an empty Discord form.
    #[must_use]
    pub fn new() -> Self {
        Self {
            bot_token: String::new(),
            guild_id: String::new(),
            allowed_user_ids: Vec::new(),
            allowed_channel_ids: Vec::new(),
        }
    }

    /// Create a form from existing configuration.
    #[must_use]
    pub fn from_config(config: &DiscordChannelConfig) -> Self {
        Self {
            bot_token: config.bot_token.resolve_plaintext(),
            guild_id: config.guild_id.clone().unwrap_or_default(),
            allowed_user_ids: config.allowed_user_ids.clone(),
            allowed_channel_ids: config.allowed_channel_ids.clone(),
        }
    }

    /// Convert form back to configuration.
    #[must_use]
    pub fn to_config(&self) -> DiscordChannelConfig {
        DiscordChannelConfig {
            bot_token: CredentialRef::Plaintext(self.bot_token.clone()),
            guild_id: if self.guild_id.trim().is_empty() {
                None
            } else {
                Some(self.guild_id.trim().to_owned())
            },
            allowed_user_ids: self.allowed_user_ids.clone(),
            allowed_channel_ids: self.allowed_channel_ids.clone(),
        }
    }

    /// Validate the form, returning an error message if invalid.
    #[must_use]
    pub fn validate(&self) -> Option<String> {
        if self.bot_token.trim().is_empty() {
            return Some("Bot token cannot be empty".to_owned());
        }
        None
    }
}

impl Default for DiscordEditForm {
    fn default() -> Self {
        Self::new()
    }
}

/// WhatsApp configuration edit form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhatsAppEditForm {
    /// Access token (plaintext for editing).
    pub access_token: String,
    /// Phone number ID.
    pub phone_number_id: String,
    /// Verify token (plaintext for editing).
    pub verify_token: String,
    /// Allowed phone numbers (E.164 format).
    pub allowed_numbers: Vec<String>,
}

impl WhatsAppEditForm {
    /// Create an empty WhatsApp form.
    #[must_use]
    pub fn new() -> Self {
        Self {
            access_token: String::new(),
            phone_number_id: String::new(),
            verify_token: String::new(),
            allowed_numbers: Vec::new(),
        }
    }

    /// Create a form from existing configuration.
    #[must_use]
    pub fn from_config(config: &WhatsAppChannelConfig) -> Self {
        Self {
            access_token: config.access_token.resolve_plaintext(),
            phone_number_id: config.phone_number_id.clone(),
            verify_token: config.verify_token.resolve_plaintext(),
            allowed_numbers: config.allowed_numbers.clone(),
        }
    }

    /// Convert form back to configuration.
    #[must_use]
    pub fn to_config(&self) -> WhatsAppChannelConfig {
        WhatsAppChannelConfig {
            access_token: CredentialRef::Plaintext(self.access_token.clone()),
            phone_number_id: self.phone_number_id.trim().to_owned(),
            verify_token: CredentialRef::Plaintext(self.verify_token.clone()),
            allowed_numbers: self.allowed_numbers.clone(),
        }
    }

    /// Validate the form, returning an error message if invalid.
    #[must_use]
    pub fn validate(&self) -> Option<String> {
        if self.access_token.trim().is_empty() {
            return Some("Access token cannot be empty".to_owned());
        }
        if self.phone_number_id.trim().is_empty() {
            return Some("Phone number ID cannot be empty".to_owned());
        }
        if self.verify_token.trim().is_empty() {
            return Some("Verify token cannot be empty".to_owned());
        }

        // Validate E.164 format for phone numbers
        for number in &self.allowed_numbers {
            if !number.starts_with('+') || number.len() < 8 {
                return Some(format!("Invalid phone number format: {number}"));
            }
        }

        None
    }
}

impl Default for WhatsAppEditForm {
    fn default() -> Self {
        Self::new()
    }
}

/// Channel health status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelHealth {
    /// Channel is connected and operational.
    Connected,
    /// Channel is disconnected or not configured.
    Disconnected,
    /// Channel has an error.
    Error,
}

/// Channel status for overview display.
#[derive(Debug, Clone)]
pub struct ChannelStatus {
    /// Channel name (e.g., "discord", "whatsapp").
    pub name: String,
    /// Health status.
    pub health: ChannelHealth,
    /// Last message timestamp (if any).
    pub last_message_time: Option<DateTime<Utc>>,
    /// Messages remaining in current rate limit window.
    pub rate_limit_remaining: Option<u32>,
}

/// Render Discord configuration form.
///
/// Returns HTML string for editing Discord channel settings.
#[must_use]
pub fn render_discord_form(form: &DiscordEditForm) -> String {
    let mut html = String::new();
    html.push_str(r#"<div class="discord-form channel-form">"#);
    html.push_str(r#"<h3>Discord Configuration</h3>"#);

    // Setup instructions (collapsible)
    html.push_str(r#"<details class="setup-instructions">
        <summary>Setup Instructions</summary>
        <ol>
            <li>Go to <a href="https://discord.com/developers/applications" target="_blank">Discord Developer Portal</a></li>
            <li>Create a new application or select an existing one</li>
            <li>Go to the "Bot" section and create a bot</li>
            <li>Copy the bot token (click "Reset Token" if needed)</li>
            <li>Enable required intents: Message Content Intent</li>
            <li>Generate OAuth2 URL with bot scope and necessary permissions</li>
            <li>Invite the bot to your server using the generated URL</li>
            <li>Copy the Guild ID and authorized user/channel IDs</li>
        </ol>
    </details>"#);

    // Bot token (masked input)
    html.push_str(
        r#"<div class="form-field">
        <label for="discord-bot-token">Bot Token <span class="required">*</span></label>
        <input type="password" id="discord-bot-token" name="bot_token" "#,
    );
    html.push_str(&format!(r#"value="{}" "#, html_escape(&form.bot_token)));
    html.push_str(
        r#"placeholder="Your Discord bot token" />
    </div>"#,
    );

    // Guild ID
    html.push_str(
        r#"<div class="form-field">
        <label for="discord-guild-id">Guild ID (optional)</label>
        <input type="text" id="discord-guild-id" name="guild_id" "#,
    );
    html.push_str(&format!(r#"value="{}" "#, html_escape(&form.guild_id)));
    html.push_str(
        r#"placeholder="e.g., 123456789012345678" />
        <p class="hint">Leave empty to monitor all guilds the bot is in.</p>
    </div>"#,
    );

    // Allowed user IDs
    html.push_str(
        r#"<div class="form-field">
        <label for="discord-allowed-users">Allowed User IDs</label>
        <div class="list-editor" id="discord-allowed-users">"#,
    );
    for user_id in &form.allowed_user_ids {
        html.push_str(&format!(
            r#"<div class="list-item">
                <span>{}</span>
                <button class="remove-btn" data-value="{}">Remove</button>
            </div>"#,
            html_escape(user_id),
            html_escape(user_id)
        ));
    }
    html.push_str(
        r#"<div class="add-item">
            <input type="text" placeholder="User ID" id="new-discord-user" />
            <button class="add-btn">Add</button>
        </div>
        </div>
    </div>"#,
    );

    // Allowed channel IDs
    html.push_str(
        r#"<div class="form-field">
        <label for="discord-allowed-channels">Allowed Channel IDs (optional)</label>
        <div class="list-editor" id="discord-allowed-channels">"#,
    );
    for channel_id in &form.allowed_channel_ids {
        html.push_str(&format!(
            r#"<div class="list-item">
                <span>{}</span>
                <button class="remove-btn" data-value="{}">Remove</button>
            </div>"#,
            html_escape(channel_id),
            html_escape(channel_id)
        ));
    }
    html.push_str(
        r#"<div class="add-item">
            <input type="text" placeholder="Channel ID" id="new-discord-channel" />
            <button class="add-btn">Add</button>
        </div>
        </div>
        <p class="hint">Leave empty to allow all channels.</p>
    </div>"#,
    );

    // Action buttons
    html.push_str(
        r#"<div class="form-actions">
        <button class="save-btn">Save</button>
        <button class="test-connection-btn">Test Connection</button>
    </div>"#,
    );

    html.push_str(r#"</div>"#); // discord-form
    html
}

/// Render WhatsApp configuration form.
///
/// Returns HTML string for editing WhatsApp channel settings.
#[must_use]
pub fn render_whatsapp_form(form: &WhatsAppEditForm) -> String {
    let mut html = String::new();
    html.push_str(r#"<div class="whatsapp-form channel-form">"#);
    html.push_str(r#"<h3>WhatsApp Configuration</h3>"#);

    // Setup instructions (collapsible)
    html.push_str(r#"<details class="setup-instructions">
        <summary>Setup Instructions</summary>
        <ol>
            <li>Go to <a href="https://developers.facebook.com/" target="_blank">Meta for Developers</a></li>
            <li>Create a new app or select an existing one</li>
            <li>Add WhatsApp product to your app</li>
            <li>Go to WhatsApp > Getting Started</li>
            <li>Copy the temporary access token (or generate a permanent one)</li>
            <li>Copy the Phone Number ID</li>
            <li>Configure webhook with verify token</li>
            <li>Add authorized phone numbers for testing</li>
        </ol>
    </details>"#);

    // Access token (masked input)
    html.push_str(
        r#"<div class="form-field">
        <label for="whatsapp-access-token">Access Token <span class="required">*</span></label>
        <input type="password" id="whatsapp-access-token" name="access_token" "#,
    );
    html.push_str(&format!(r#"value="{}" "#, html_escape(&form.access_token)));
    html.push_str(
        r#"placeholder="Your WhatsApp access token" />
    </div>"#,
    );

    // Phone number ID
    html.push_str(
        r#"<div class="form-field">
        <label for="whatsapp-phone-id">Phone Number ID <span class="required">*</span></label>
        <input type="text" id="whatsapp-phone-id" name="phone_number_id" "#,
    );
    html.push_str(&format!(
        r#"value="{}" "#,
        html_escape(&form.phone_number_id)
    ));
    html.push_str(
        r#"placeholder="e.g., 123456789012345" />
    </div>"#,
    );

    // Verify token (masked input)
    html.push_str(
        r#"<div class="form-field">
        <label for="whatsapp-verify-token">Verify Token <span class="required">*</span></label>
        <input type="password" id="whatsapp-verify-token" name="verify_token" "#,
    );
    html.push_str(&format!(r#"value="{}" "#, html_escape(&form.verify_token)));
    html.push_str(
        r#"placeholder="Your webhook verify token" />
        <p class="hint">Used for webhook verification by Meta.</p>
    </div>"#,
    );

    // Allowed numbers
    html.push_str(
        r#"<div class="form-field">
        <label for="whatsapp-allowed-numbers">Allowed Phone Numbers</label>
        <div class="list-editor" id="whatsapp-allowed-numbers">"#,
    );
    for number in &form.allowed_numbers {
        html.push_str(&format!(
            r#"<div class="list-item">
                <span>{}</span>
                <button class="remove-btn" data-value="{}">Remove</button>
            </div>"#,
            html_escape(number),
            html_escape(number)
        ));
    }
    html.push_str(
        r#"<div class="add-item">
            <input type="text" placeholder="+14155551234" id="new-whatsapp-number" />
            <button class="add-btn">Add</button>
        </div>
        </div>
        <p class="hint">Use E.164 format (e.g., +14155551234).</p>
    </div>"#,
    );

    // Action buttons
    html.push_str(
        r#"<div class="form-actions">
        <button class="save-btn">Save</button>
        <button class="test-connection-btn">Test Connection</button>
    </div>"#,
    );

    html.push_str(r#"</div>"#); // whatsapp-form
    html
}

/// Channel filter for message history.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryChannelFilter {
    /// Show all messages from all channels.
    All,
    /// Show only Discord messages.
    Discord,
    /// Show only WhatsApp messages.
    WhatsApp,
}

/// Render message history viewer with channel filtering.
///
/// Returns HTML string for message history display.
#[must_use]
pub fn render_message_history(messages: &[ChannelMessage], filter: HistoryChannelFilter) -> String {
    let mut html = String::new();
    html.push_str(r#"<div class="message-history">"#);
    html.push_str(r#"<h3>Message History</h3>"#);

    // Channel filter tabs
    html.push_str(r#"<div class="history-filters">"#);
    let all_active = if filter == HistoryChannelFilter::All {
        " active"
    } else {
        ""
    };
    let discord_active = if filter == HistoryChannelFilter::Discord {
        " active"
    } else {
        ""
    };
    let whatsapp_active = if filter == HistoryChannelFilter::WhatsApp {
        " active"
    } else {
        ""
    };

    html.push_str(&format!(
        r#"<button class="filter-btn{}" data-filter="all">All</button>"#,
        all_active
    ));
    html.push_str(&format!(
        r#"<button class="filter-btn{}" data-filter="discord">Discord</button>"#,
        discord_active
    ));
    html.push_str(&format!(
        r#"<button class="filter-btn{}" data-filter="whatsapp">WhatsApp</button>"#,
        whatsapp_active
    ));
    html.push_str(r#"</div>"#); // history-filters

    // Filter messages by channel
    let filtered_messages: Vec<&ChannelMessage> = messages
        .iter()
        .filter(|msg| match filter {
            HistoryChannelFilter::All => true,
            HistoryChannelFilter::Discord => msg.channel == "discord",
            HistoryChannelFilter::WhatsApp => msg.channel == "whatsapp",
        })
        .collect();

    if filtered_messages.is_empty() {
        html.push_str(
            r#"<div class="history-empty">
            <p>No messages yet</p>
            <p class="hint">Messages will appear here once channels start communicating.</p>
        </div>"#,
        );
    } else {
        html.push_str(r#"<div class="message-list">"#);

        for message in &filtered_messages {
            let alignment = match message.direction {
                MessageDirection::Inbound => "inbound",
                MessageDirection::Outbound => "outbound",
            };

            let direction_label = match message.direction {
                MessageDirection::Inbound => "Received",
                MessageDirection::Outbound => "Sent",
            };

            let timestamp = message.timestamp.format("%Y-%m-%d %H:%M:%S UTC");

            html.push_str(&format!(
                r#"<div class="message-item {}">
                    <div class="message-header">
                        <span class="channel-badge">{}</span>
                        <span class="direction">{}</span>
                        <span class="sender">{}</span>
                        <span class="timestamp">{}</span>
                    </div>
                    <div class="message-text">{}</div>
                </div>"#,
                alignment,
                html_escape(&message.channel),
                direction_label,
                html_escape(&message.sender),
                timestamp,
                html_escape(&message.text).replace('\n', "<br>")
            ));
        }

        html.push_str(r#"</div>"#); // message-list
    }

    // Clear history buttons
    html.push_str(r#"<div class="history-actions">"#);
    match filter {
        HistoryChannelFilter::All => {
            html.push_str(
                r#"<button class="clear-history-btn" data-channel="all">Clear All History</button>"#,
            );
        }
        HistoryChannelFilter::Discord => {
            html.push_str(
                r#"<button class="clear-history-btn" data-channel="discord">Clear Discord History</button>"#,
            );
        }
        HistoryChannelFilter::WhatsApp => {
            html.push_str(
                r#"<button class="clear-history-btn" data-channel="whatsapp">Clear WhatsApp History</button>"#,
            );
        }
    }
    html.push_str(r#"</div>"#); // history-actions

    html.push_str(r#"</div>"#); // message-history
    html
}

/// Escape HTML special characters.
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
}

/// Render channel overview with health indicators and status.
///
/// Returns HTML string for display.
#[must_use]
pub fn render_channel_overview(channels: &[ChannelStatus], auto_start: bool) -> String {
    if channels.is_empty() {
        return r#"<div class="channel-overview-empty">
            <p>No channels configured</p>
            <p class="hint">Use the Discord and WhatsApp tabs to configure channels.</p>
        </div>"#
            .to_owned();
    }

    let mut html = String::new();
    html.push_str(r#"<div class="channel-overview">"#);

    // Auto-start toggle status
    let auto_start_status = if auto_start { "enabled" } else { "disabled" };
    html.push_str(&format!(
        r#"<div class="auto-start-status">Auto-start: <span class="{}">{}</span></div>"#,
        auto_start_status, auto_start_status
    ));

    html.push_str(r#"<div class="channel-list">"#);

    for channel in channels {
        let (health_class, health_text) = match channel.health {
            ChannelHealth::Connected => ("connected", "Connected"),
            ChannelHealth::Disconnected => ("disconnected", "Disconnected"),
            ChannelHealth::Error => ("error", "Error"),
        };

        let last_message = match &channel.last_message_time {
            Some(time) => format!("Last message: {}", time.format("%Y-%m-%d %H:%M:%S UTC")),
            None => "No messages yet".to_owned(),
        };

        let rate_limit = match channel.rate_limit_remaining {
            Some(remaining) => format!("Rate limit: {} remaining", remaining),
            None => String::new(),
        };

        html.push_str(&format!(
            r#"<div class="channel-item">
                <div class="channel-name">{}</div>
                <div class="channel-health {}">
                    <span class="status-indicator"></span>
                    {}
                </div>
                <div class="channel-info">{}</div>
                <div class="channel-rate-limit">{}</div>
                <button class="configure-btn" data-channel="{}">Configure</button>
            </div>"#,
            channel.name, health_class, health_text, last_message, rate_limit, channel.name
        ));
    }

    html.push_str(r#"</div>"#); // channel-list
    html.push_str(r#"<button class="refresh-health-btn">Refresh Health</button>"#);
    html.push_str(r#"</div>"#); // channel-overview

    html
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn discord_form_new() {
        let form = DiscordEditForm::new();
        assert!(form.bot_token.is_empty());
        assert!(form.guild_id.is_empty());
        assert!(form.allowed_user_ids.is_empty());
        assert!(form.allowed_channel_ids.is_empty());
    }

    #[test]
    fn discord_form_round_trip() {
        let config = DiscordChannelConfig {
            bot_token: CredentialRef::Plaintext("test_token".to_owned()),
            guild_id: Some("123456".to_owned()),
            allowed_user_ids: vec!["user1".to_owned(), "user2".to_owned()],
            allowed_channel_ids: vec!["chan1".to_owned()],
        };

        let form = DiscordEditForm::from_config(&config);
        assert!(form.bot_token == "test_token");
        assert!(form.guild_id == "123456");
        assert!(form.allowed_user_ids.len() == 2);

        let config2 = form.to_config();
        assert!(config2.bot_token.resolve_plaintext() == "test_token");
        assert!(config2.guild_id == Some("123456".to_owned()));
        assert!(config2.allowed_user_ids.len() == 2);
    }

    #[test]
    fn discord_form_validation_empty_token() {
        let form = DiscordEditForm {
            bot_token: String::new(),
            guild_id: "123".to_owned(),
            allowed_user_ids: vec!["user1".to_owned()],
            allowed_channel_ids: Vec::new(),
        };

        let error = form.validate();
        assert!(error.is_some());
        match error {
            Some(msg) => assert!(msg.contains("token")),
            None => unreachable!("expected validation error"),
        }
    }

    #[test]
    fn discord_form_validation_valid() {
        let form = DiscordEditForm {
            bot_token: "valid_token".to_owned(),
            guild_id: "123".to_owned(),
            allowed_user_ids: vec!["user1".to_owned()],
            allowed_channel_ids: Vec::new(),
        };

        assert!(form.validate().is_none());
    }

    #[test]
    fn whatsapp_form_new() {
        let form = WhatsAppEditForm::new();
        assert!(form.access_token.is_empty());
        assert!(form.phone_number_id.is_empty());
        assert!(form.verify_token.is_empty());
        assert!(form.allowed_numbers.is_empty());
    }

    #[test]
    fn whatsapp_form_round_trip() {
        let config = WhatsAppChannelConfig {
            access_token: CredentialRef::Plaintext("test_access".to_owned()),
            phone_number_id: "phone123".to_owned(),
            verify_token: CredentialRef::Plaintext("verify123".to_owned()),
            allowed_numbers: vec!["+14155551234".to_owned()],
        };

        let form = WhatsAppEditForm::from_config(&config);
        assert!(form.access_token == "test_access");
        assert!(form.phone_number_id == "phone123");
        assert!(form.verify_token == "verify123");
        assert!(form.allowed_numbers.len() == 1);

        let config2 = form.to_config();
        assert!(config2.access_token.resolve_plaintext() == "test_access");
        assert!(config2.phone_number_id == "phone123");
        assert!(config2.allowed_numbers[0] == "+14155551234");
    }

    #[test]
    fn whatsapp_form_validation_empty_token() {
        let form = WhatsAppEditForm {
            access_token: String::new(),
            phone_number_id: "phone123".to_owned(),
            verify_token: "verify".to_owned(),
            allowed_numbers: Vec::new(),
        };

        let error = form.validate();
        assert!(error.is_some());
        match error {
            Some(msg) => assert!(msg.contains("Access token")),
            None => unreachable!("expected validation error"),
        }
    }

    #[test]
    fn whatsapp_form_validation_empty_phone_id() {
        let form = WhatsAppEditForm {
            access_token: "token".to_owned(),
            phone_number_id: String::new(),
            verify_token: "verify".to_owned(),
            allowed_numbers: Vec::new(),
        };

        let error = form.validate();
        assert!(error.is_some());
        match error {
            Some(msg) => assert!(msg.contains("Phone number ID")),
            None => unreachable!("expected validation error"),
        }
    }

    #[test]
    fn whatsapp_form_validation_invalid_phone_format() {
        let form = WhatsAppEditForm {
            access_token: "token".to_owned(),
            phone_number_id: "phone123".to_owned(),
            verify_token: "verify".to_owned(),
            allowed_numbers: vec!["4155551234".to_owned()], // Missing +
        };

        let error = form.validate();
        assert!(error.is_some());
        match error {
            Some(msg) => assert!(msg.contains("Invalid phone number")),
            None => unreachable!("expected validation error"),
        }
    }

    #[test]
    fn whatsapp_form_validation_valid() {
        let form = WhatsAppEditForm {
            access_token: "token".to_owned(),
            phone_number_id: "phone123".to_owned(),
            verify_token: "verify".to_owned(),
            allowed_numbers: vec!["+14155551234".to_owned()],
        };

        assert!(form.validate().is_none());
    }

    #[test]
    fn render_overview_no_channels() {
        let html = render_channel_overview(&[], true);
        assert!(html.contains("No channels configured"));
        assert!(html.contains("channel-overview-empty"));
    }

    #[test]
    fn render_overview_with_discord_only() {
        let channels = vec![ChannelStatus {
            name: "discord".to_owned(),
            health: ChannelHealth::Connected,
            last_message_time: Some(Utc::now()),
            rate_limit_remaining: Some(15),
        }];

        let html = render_channel_overview(&channels, true);
        assert!(html.contains("discord"));
        assert!(html.contains("Connected"));
        assert!(html.contains("Rate limit: 15 remaining"));
        assert!(html.contains("Auto-start"));
    }

    #[test]
    fn render_overview_with_both_channels() {
        let channels = vec![
            ChannelStatus {
                name: "discord".to_owned(),
                health: ChannelHealth::Connected,
                last_message_time: Some(Utc::now()),
                rate_limit_remaining: Some(15),
            },
            ChannelStatus {
                name: "whatsapp".to_owned(),
                health: ChannelHealth::Disconnected,
                last_message_time: None,
                rate_limit_remaining: Some(10),
            },
        ];

        let html = render_channel_overview(&channels, false);
        assert!(html.contains("discord"));
        assert!(html.contains("whatsapp"));
        assert!(html.contains("Connected"));
        assert!(html.contains("Disconnected"));
        assert!(html.contains("No messages yet"));
    }

    #[test]
    fn render_overview_health_status_display() {
        let channels = vec![
            ChannelStatus {
                name: "discord".to_owned(),
                health: ChannelHealth::Connected,
                last_message_time: None,
                rate_limit_remaining: None,
            },
            ChannelStatus {
                name: "whatsapp".to_owned(),
                health: ChannelHealth::Error,
                last_message_time: None,
                rate_limit_remaining: None,
            },
        ];

        let html = render_channel_overview(&channels, true);
        assert!(html.contains("connected"));
        assert!(html.contains("error"));
        assert!(html.contains("Refresh Health"));
    }

    #[test]
    fn render_discord_form_empty() {
        let form = DiscordEditForm::new();
        let html = render_discord_form(&form);

        assert!(html.contains("Discord Configuration"));
        assert!(html.contains("Bot Token"));
        assert!(html.contains("Setup Instructions"));
        assert!(html.contains("Test Connection"));
        assert!(html.contains("Save"));
    }

    #[test]
    fn render_discord_form_with_config() {
        let form = DiscordEditForm {
            bot_token: "test_token".to_owned(),
            guild_id: "123456".to_owned(),
            allowed_user_ids: vec!["user1".to_owned(), "user2".to_owned()],
            allowed_channel_ids: vec!["chan1".to_owned()],
        };

        let html = render_discord_form(&form);
        assert!(html.contains("test_token"));
        assert!(html.contains("123456"));
        assert!(html.contains("user1"));
        assert!(html.contains("user2"));
        assert!(html.contains("chan1"));
    }

    #[test]
    fn render_whatsapp_form_empty() {
        let form = WhatsAppEditForm::new();
        let html = render_whatsapp_form(&form);

        assert!(html.contains("WhatsApp Configuration"));
        assert!(html.contains("Access Token"));
        assert!(html.contains("Phone Number ID"));
        assert!(html.contains("Verify Token"));
        assert!(html.contains("E.164 format"));
        assert!(html.contains("Test Connection"));
    }

    #[test]
    fn render_whatsapp_form_with_config() {
        let form = WhatsAppEditForm {
            access_token: "test_access".to_owned(),
            phone_number_id: "phone123".to_owned(),
            verify_token: "verify_token".to_owned(),
            allowed_numbers: vec!["+14155551234".to_owned(), "+14155555678".to_owned()],
        };

        let html = render_whatsapp_form(&form);
        assert!(html.contains("test_access"));
        assert!(html.contains("phone123"));
        assert!(html.contains("verify_token"));
        assert!(html.contains("+14155551234"));
        assert!(html.contains("+14155555678"));
    }

    #[test]
    fn html_escape_special_chars() {
        assert!(html_escape("<script>") == "&lt;script&gt;");
        assert!(html_escape("a & b") == "a &amp; b");
        assert!(html_escape("\"quote\"") == "&quot;quote&quot;");
    }

    #[test]
    fn render_history_empty() {
        let html = render_message_history(&[], HistoryChannelFilter::All);
        assert!(html.contains("No messages yet"));
        assert!(html.contains("history-empty"));
        assert!(html.contains("Clear All History"));
    }

    #[test]
    fn render_history_with_messages() {
        let messages = vec![
            ChannelMessage {
                id: "1".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Inbound,
                sender: "user123".to_owned(),
                text: "Hello!".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
            ChannelMessage {
                id: "2".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Outbound,
                sender: "fae".to_owned(),
                text: "Hi there!".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
        ];

        let html = render_message_history(&messages, HistoryChannelFilter::All);
        assert!(html.contains("Hello!"));
        assert!(html.contains("Hi there!"));
        assert!(html.contains("user123"));
        assert!(html.contains("discord"));
        assert!(html.contains("inbound"));
        assert!(html.contains("outbound"));
    }

    #[test]
    fn render_history_filter_by_channel() {
        let messages = vec![
            ChannelMessage {
                id: "1".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Inbound,
                sender: "user123".to_owned(),
                text: "Discord message".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
            ChannelMessage {
                id: "2".to_owned(),
                channel: "whatsapp".to_owned(),
                direction: MessageDirection::Inbound,
                sender: "+14155551234".to_owned(),
                text: "WhatsApp message".to_owned(),
                timestamp: Utc::now(),
                reply_target: "+14155555678".to_owned(),
            },
        ];

        // Filter Discord only
        let html_discord = render_message_history(&messages, HistoryChannelFilter::Discord);
        assert!(html_discord.contains("Discord message"));
        assert!(!html_discord.contains("WhatsApp message"));
        assert!(html_discord.contains("Clear Discord History"));

        // Filter WhatsApp only
        let html_whatsapp = render_message_history(&messages, HistoryChannelFilter::WhatsApp);
        assert!(!html_whatsapp.contains("Discord message"));
        assert!(html_whatsapp.contains("WhatsApp message"));
        assert!(html_whatsapp.contains("Clear WhatsApp History"));
    }

    #[test]
    fn render_history_direction_styling() {
        let messages = vec![
            ChannelMessage {
                id: "1".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Inbound,
                sender: "user123".to_owned(),
                text: "Inbound".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
            ChannelMessage {
                id: "2".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Outbound,
                sender: "fae".to_owned(),
                text: "Outbound".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
        ];

        let html = render_message_history(&messages, HistoryChannelFilter::All);
        assert!(html.contains(r#"message-item inbound"#));
        assert!(html.contains(r#"message-item outbound"#));
        assert!(html.contains("Received"));
        assert!(html.contains("Sent"));
    }

    #[test]
    fn integration_workflow_configure_discord() {
        // Step 1: Create a new form
        let mut form = DiscordEditForm::new();
        assert!(form.bot_token.is_empty());

        // Step 2: Fill in configuration
        form.bot_token = "test_bot_token_123".to_owned();
        form.guild_id = "987654321".to_owned();
        form.allowed_user_ids.push("user1".to_owned());
        form.allowed_user_ids.push("user2".to_owned());

        // Step 3: Validate
        assert!(form.validate().is_none());

        // Step 4: Convert to config
        let config = form.to_config();
        assert!(config.bot_token.resolve_plaintext() == "test_bot_token_123");
        assert!(config.guild_id == Some("987654321".to_owned()));
        assert!(config.allowed_user_ids.len() == 2);

        // Step 5: Render the form HTML
        let html = render_discord_form(&form);
        assert!(html.contains("test_bot_token_123"));
        assert!(html.contains("user1"));

        // Step 6: Round-trip back to form
        let form2 = DiscordEditForm::from_config(&config);
        assert!(form2.bot_token == form.bot_token);
        assert!(form2.guild_id == form.guild_id);
        assert!(form2.allowed_user_ids == form.allowed_user_ids);
    }

    #[test]
    fn integration_workflow_view_history() {
        // Step 1: Create some messages
        let messages = vec![
            ChannelMessage {
                id: "1".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Inbound,
                sender: "user123".to_owned(),
                text: "Hello Fae!".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
            ChannelMessage {
                id: "2".to_owned(),
                channel: "discord".to_owned(),
                direction: MessageDirection::Outbound,
                sender: "fae".to_owned(),
                text: "Hello! How can I help?".to_owned(),
                timestamp: Utc::now(),
                reply_target: "chan1".to_owned(),
            },
            ChannelMessage {
                id: "3".to_owned(),
                channel: "whatsapp".to_owned(),
                direction: MessageDirection::Inbound,
                sender: "+14155551234".to_owned(),
                text: "Test message".to_owned(),
                timestamp: Utc::now(),
                reply_target: "+14155555678".to_owned(),
            },
        ];

        // Step 2: Render all messages
        let html_all = render_message_history(&messages, HistoryChannelFilter::All);
        assert!(html_all.contains("Hello Fae!"));
        assert!(html_all.contains("Test message"));

        // Step 3: Filter by Discord
        let html_discord = render_message_history(&messages, HistoryChannelFilter::Discord);
        assert!(html_discord.contains("Hello Fae!"));
        assert!(!html_discord.contains("Test message"));

        // Step 4: Filter by WhatsApp
        let html_whatsapp = render_message_history(&messages, HistoryChannelFilter::WhatsApp);
        assert!(!html_whatsapp.contains("Hello Fae!"));
        assert!(html_whatsapp.contains("Test message"));
    }

    #[test]
    fn integration_validation_errors() {
        // Discord form with empty token
        let discord_form = DiscordEditForm {
            bot_token: String::new(),
            guild_id: "123".to_owned(),
            allowed_user_ids: vec!["user1".to_owned()],
            allowed_channel_ids: Vec::new(),
        };
        assert!(discord_form.validate().is_some());

        // WhatsApp form with invalid phone number
        let whatsapp_form = WhatsAppEditForm {
            access_token: "token".to_owned(),
            phone_number_id: "phone123".to_owned(),
            verify_token: "verify".to_owned(),
            allowed_numbers: vec!["4155551234".to_owned()], // Missing +
        };
        assert!(whatsapp_form.validate().is_some());
    }
}
