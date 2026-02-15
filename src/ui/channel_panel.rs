//! Channel management UI panel types and state.
//!
//! Provides types for managing the channel UI panel, including editing
//! Discord and WhatsApp configurations, viewing message history, and
//! monitoring channel health.

use crate::config::{DiscordChannelConfig, WhatsAppChannelConfig};
use crate::credentials::CredentialRef;
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
}
