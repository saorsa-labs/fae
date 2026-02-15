//! Channel message history storage.
//!
//! Stores recent inbound and outbound messages for UI display and debugging.
//! Uses a fixed-capacity ring buffer to prevent unbounded growth.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

/// Direction of a channel message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageDirection {
    /// Message received from external channel.
    Inbound,
    /// Message sent to external channel.
    Outbound,
}

/// A recorded channel message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelMessage {
    /// Unique message identifier (generated on record).
    pub id: String,
    /// Channel name (e.g., "discord", "whatsapp").
    pub channel: String,
    /// Direction (inbound or outbound).
    pub direction: MessageDirection,
    /// Sender identifier (user ID, phone number, etc.).
    pub sender: String,
    /// Message text content.
    pub text: String,
    /// Timestamp when message was recorded.
    pub timestamp: DateTime<Utc>,
    /// Reply target (channel-specific, e.g., Discord message ID, WhatsApp phone).
    pub reply_target: String,
}

/// Channel message history with fixed capacity.
#[derive(Debug, Clone)]
pub struct ChannelHistory {
    /// Messages stored in insertion order (oldest first).
    messages: VecDeque<ChannelMessage>,
    /// Maximum number of messages to retain.
    max_messages: usize,
    /// Counter for generating message IDs.
    next_id: u64,
}

impl ChannelHistory {
    /// Create a new history with the given capacity.
    #[must_use]
    pub fn new(max_messages: usize) -> Self {
        Self {
            messages: VecDeque::with_capacity(max_messages),
            max_messages,
            next_id: 1,
        }
    }

    /// Push a new message, evicting the oldest if at capacity.
    pub fn push(&mut self, mut message: ChannelMessage) {
        // Generate ID if not set
        if message.id.is_empty() {
            message.id = format!("msg_{}", self.next_id);
            self.next_id = self.next_id.wrapping_add(1);
        }

        // Evict oldest if at capacity
        if self.messages.len() >= self.max_messages {
            self.messages.pop_front();
        }

        self.messages.push_back(message);
    }

    /// Get all messages for a specific channel, in reverse chronological order.
    #[must_use]
    pub fn messages_for_channel(&self, channel: &str) -> Vec<ChannelMessage> {
        self.messages
            .iter()
            .filter(|m| m.channel == channel)
            .rev()
            .cloned()
            .collect()
    }

    /// Get all messages across all channels, in reverse chronological order.
    #[must_use]
    pub fn all_messages(&self) -> Vec<ChannelMessage> {
        self.messages.iter().rev().cloned().collect()
    }

    /// Clear all messages for a specific channel.
    pub fn clear_channel(&mut self, channel: &str) {
        self.messages.retain(|m| m.channel != channel);
    }

    /// Get the total number of messages stored.
    #[must_use]
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    /// Check if the history is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }
}

impl Default for ChannelHistory {
    fn default() -> Self {
        Self::new(500)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn make_message(channel: &str, direction: MessageDirection, text: &str) -> ChannelMessage {
        ChannelMessage {
            id: String::new(),
            channel: channel.to_owned(),
            direction,
            sender: "test_sender".to_owned(),
            text: text.to_owned(),
            timestamp: Utc::now(),
            reply_target: "test_target".to_owned(),
        }
    }

    #[test]
    fn push_and_retrieve() {
        let mut history = ChannelHistory::new(10);

        let msg1 = make_message("discord", MessageDirection::Inbound, "hello");
        let msg2 = make_message("discord", MessageDirection::Outbound, "hi there");

        history.push(msg1.clone());
        history.push(msg2.clone());

        let all = history.all_messages();
        assert!(all.len() == 2);

        // Reverse chronological order
        assert!(all[0].text == "hi there");
        assert!(all[1].text == "hello");
    }

    #[test]
    fn max_capacity_eviction() {
        let mut history = ChannelHistory::new(3);

        history.push(make_message("discord", MessageDirection::Inbound, "msg1"));
        history.push(make_message("discord", MessageDirection::Inbound, "msg2"));
        history.push(make_message("discord", MessageDirection::Inbound, "msg3"));
        history.push(make_message("discord", MessageDirection::Inbound, "msg4"));

        assert!(history.len() == 3);

        let all = history.all_messages();
        assert!(all[0].text == "msg4");
        assert!(all[1].text == "msg3");
        assert!(all[2].text == "msg2");
    }

    #[test]
    fn filter_by_channel() {
        let mut history = ChannelHistory::new(10);

        history.push(make_message(
            "discord",
            MessageDirection::Inbound,
            "discord1",
        ));
        history.push(make_message(
            "whatsapp",
            MessageDirection::Inbound,
            "whatsapp1",
        ));
        history.push(make_message(
            "discord",
            MessageDirection::Outbound,
            "discord2",
        ));

        let discord_msgs = history.messages_for_channel("discord");
        assert!(discord_msgs.len() == 2);
        assert!(discord_msgs[0].text == "discord2");
        assert!(discord_msgs[1].text == "discord1");

        let whatsapp_msgs = history.messages_for_channel("whatsapp");
        assert!(whatsapp_msgs.len() == 1);
        assert!(whatsapp_msgs[0].text == "whatsapp1");
    }

    #[test]
    fn clear_channel() {
        let mut history = ChannelHistory::new(10);

        history.push(make_message(
            "discord",
            MessageDirection::Inbound,
            "discord1",
        ));
        history.push(make_message(
            "whatsapp",
            MessageDirection::Inbound,
            "whatsapp1",
        ));
        history.push(make_message(
            "discord",
            MessageDirection::Outbound,
            "discord2",
        ));

        assert!(history.len() == 3);

        history.clear_channel("discord");

        assert!(history.len() == 1);
        let remaining = history.all_messages();
        assert!(remaining[0].text == "whatsapp1");
    }

    #[test]
    fn auto_generate_ids() {
        let mut history = ChannelHistory::new(10);

        let msg1 = make_message("discord", MessageDirection::Inbound, "test1");
        let msg2 = make_message("discord", MessageDirection::Inbound, "test2");

        // IDs start empty
        assert!(msg1.id.is_empty());
        assert!(msg2.id.is_empty());

        history.push(msg1.clone());
        history.push(msg2.clone());

        let all = history.all_messages();
        assert!(all[0].id == "msg_2");
        assert!(all[1].id == "msg_1");
    }

    #[test]
    fn preserves_existing_ids() {
        let mut history = ChannelHistory::new(10);

        let mut msg = make_message("discord", MessageDirection::Inbound, "test");
        msg.id = "custom_id".to_owned();

        history.push(msg);

        let all = history.all_messages();
        assert!(all[0].id == "custom_id");
    }

    #[test]
    fn empty_and_len() {
        let mut history = ChannelHistory::new(10);

        assert!(history.is_empty());
        assert!(history.is_empty());

        history.push(make_message("discord", MessageDirection::Inbound, "test"));

        assert!(!history.is_empty());
        assert!(history.len() == 1);
    }
}
