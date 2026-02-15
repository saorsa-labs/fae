//! Rate limiting for outbound channel messages.
//!
//! Provides per-channel rate limiting to prevent API abuse and stay within
//! platform limits. Each channel has an independent token bucket with a
//! sliding window implementation.

use std::collections::{HashMap, VecDeque};
use std::time::Instant;
use thiserror::Error;

/// Rate limiting error.
#[derive(Debug, Clone, Error)]
pub enum RateLimitError {
    /// Rate limit exceeded; must wait before sending.
    #[error("rate limit exceeded; retry after {retry_after_secs}s")]
    Exceeded {
        /// Seconds to wait before retry.
        retry_after_secs: u64,
    },
}

/// Per-channel rate limiter using sliding window.
#[derive(Debug, Clone)]
pub struct RateLimiter {
    /// Maximum messages allowed per minute.
    max_messages_per_minute: u32,
    /// Sliding window of message timestamps.
    window: VecDeque<Instant>,
}

impl RateLimiter {
    /// Create a new rate limiter with the given per-minute limit.
    #[must_use]
    pub fn new(max_messages_per_minute: u32) -> Self {
        Self {
            max_messages_per_minute,
            window: VecDeque::new(),
        }
    }

    /// Try to send a message, returning an error if rate limit is exceeded.
    ///
    /// On success, records the send timestamp and returns `Ok(())`.
    /// On failure, returns `RateLimitError::Exceeded` with retry delay.
    pub fn try_send(&mut self) -> Result<(), RateLimitError> {
        let now = Instant::now();
        let window_start = now - std::time::Duration::from_secs(60);

        // Remove timestamps outside the 60-second window
        while let Some(&first) = self.window.front() {
            if first < window_start {
                self.window.pop_front();
            } else {
                break;
            }
        }

        // Check if we're at capacity
        if self.window.len() >= self.max_messages_per_minute as usize {
            // Find time until the oldest message ages out
            if let Some(&oldest) = self.window.front() {
                let age = now.duration_since(oldest);
                let remaining = std::time::Duration::from_secs(60).saturating_sub(age);
                let retry_after_secs = remaining.as_secs().saturating_add(1);
                return Err(RateLimitError::Exceeded { retry_after_secs });
            }
        }

        // Allow the send and record timestamp
        self.window.push_back(now);
        Ok(())
    }

    /// Get the number of messages remaining in the current window.
    #[must_use]
    pub fn remaining(&self) -> u32 {
        self.max_messages_per_minute
            .saturating_sub(self.window.len() as u32)
    }
}

/// Rate limits configuration for all channels.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ChannelRateLimits {
    /// Discord rate limit (messages per minute).
    pub discord: u32,
    /// WhatsApp rate limit (messages per minute).
    pub whatsapp: u32,
}

impl Default for ChannelRateLimits {
    fn default() -> Self {
        Self {
            discord: 20,
            whatsapp: 10,
        }
    }
}

/// Multi-channel rate limiter manager.
#[derive(Debug)]
pub struct ChannelRateLimiters {
    limiters: HashMap<String, RateLimiter>,
}

impl ChannelRateLimiters {
    /// Create a new multi-channel rate limiter from configuration.
    #[must_use]
    pub fn new(config: &ChannelRateLimits) -> Self {
        let mut limiters = HashMap::new();
        limiters.insert("discord".to_owned(), RateLimiter::new(config.discord));
        limiters.insert("whatsapp".to_owned(), RateLimiter::new(config.whatsapp));
        Self { limiters }
    }

    /// Try to send a message on the given channel.
    pub fn try_send(&mut self, channel: &str) -> Result<(), RateLimitError> {
        if let Some(limiter) = self.limiters.get_mut(channel) {
            limiter.try_send()
        } else {
            // Unknown channel - allow by default
            Ok(())
        }
    }

    /// Get remaining messages for a channel.
    #[must_use]
    pub fn remaining(&self, channel: &str) -> Option<u32> {
        self.limiters.get(channel).map(|l| l.remaining())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn rate_limiter_allows_within_limit() {
        let mut limiter = RateLimiter::new(5);

        for _ in 0..5 {
            assert!(limiter.try_send().is_ok());
        }
    }

    #[test]
    fn rate_limiter_blocks_exceeding_limit() {
        let mut limiter = RateLimiter::new(3);

        for _ in 0..3 {
            assert!(limiter.try_send().is_ok());
        }

        let result = limiter.try_send();
        assert!(result.is_err());
        match result {
            Err(RateLimitError::Exceeded { retry_after_secs }) => {
                assert!(retry_after_secs > 0);
                assert!(retry_after_secs <= 60);
            }
            _ => unreachable!("expected rate limit exceeded"),
        }
    }

    #[test]
    fn rate_limiter_window_slides() {
        let mut limiter = RateLimiter::new(2);

        assert!(limiter.try_send().is_ok());
        thread::sleep(Duration::from_millis(100));
        assert!(limiter.try_send().is_ok());

        // Third send should be blocked
        let result = limiter.try_send();
        assert!(result.is_err());

        // After 60+ seconds, window should have cleared
        // This is too slow for unit tests, so we just verify the error structure
        match result {
            Err(RateLimitError::Exceeded { retry_after_secs }) => {
                assert!(retry_after_secs > 0);
                assert!(retry_after_secs <= 60);
            }
            _ => unreachable!("expected rate limit exceeded"),
        }
    }

    #[test]
    fn rate_limiter_remaining_count() {
        let mut limiter = RateLimiter::new(5);

        assert!(limiter.remaining() == 5);

        assert!(limiter.try_send().is_ok());
        assert!(limiter.remaining() == 4);

        assert!(limiter.try_send().is_ok());
        assert!(limiter.remaining() == 3);
    }

    #[test]
    fn channel_rate_limiters_per_channel_isolation() {
        let config = ChannelRateLimits {
            discord: 2,
            whatsapp: 3,
        };
        let mut limiters = ChannelRateLimiters::new(&config);

        // Discord limit
        assert!(limiters.try_send("discord").is_ok());
        assert!(limiters.try_send("discord").is_ok());
        assert!(limiters.try_send("discord").is_err());

        // WhatsApp should be independent
        assert!(limiters.try_send("whatsapp").is_ok());
        assert!(limiters.try_send("whatsapp").is_ok());
        assert!(limiters.try_send("whatsapp").is_ok());
        assert!(limiters.try_send("whatsapp").is_err());
    }

    #[test]
    fn channel_rate_limiters_unknown_channel_allowed() {
        let config = ChannelRateLimits::default();
        let mut limiters = ChannelRateLimiters::new(&config);

        // Unknown channel should allow by default
        assert!(limiters.try_send("unknown").is_ok());
    }

    #[test]
    fn channel_rate_limiters_remaining() {
        let config = ChannelRateLimits {
            discord: 5,
            whatsapp: 3,
        };
        let mut limiters = ChannelRateLimiters::new(&config);

        assert!(limiters.remaining("discord") == Some(5));
        assert!(limiters.remaining("whatsapp") == Some(3));

        assert!(limiters.try_send("discord").is_ok());
        assert!(limiters.remaining("discord") == Some(4));

        assert!(limiters.remaining("unknown").is_none());
    }
}
