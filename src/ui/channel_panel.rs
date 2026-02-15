//! Channel management UI panel types and state.
//!
//! Provides types for managing the channel UI panel, including editing
//! Discord and WhatsApp configurations, viewing message history, and
//! monitoring channel health.

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
}
