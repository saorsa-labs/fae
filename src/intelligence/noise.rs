//! Noise control for proactive intelligence delivery.
//!
//! Prevents Fae from becoming annoying by enforcing daily budgets,
//! cooldown periods, deduplication, and quiet hours.

use std::collections::HashSet;
use std::hash::{DefaultHasher, Hash, Hasher};

/// Controls how frequently proactive intelligence can be delivered.
///
/// Enforces:
/// - Daily interruption budget (max deliveries per day)
/// - Cooldown between deliveries (minimum seconds between interruptions)
/// - Content deduplication (don't repeat the same insight)
/// - Quiet hours (no delivery during sleep/focus windows)
#[derive(Debug, Clone)]
pub struct NoiseController {
    /// Maximum deliveries allowed per day.
    daily_budget: u32,
    /// Deliveries made so far today.
    deliveries_today: u32,
    /// Epoch seconds of last delivery.
    last_delivery_at: Option<u64>,
    /// Minimum seconds between deliveries.
    cooldown_secs: u64,
    /// Set of content hashes delivered recently (for dedup).
    recent_hashes: HashSet<u64>,
    /// Start of quiet hours (hour 0-23).
    quiet_start: u8,
    /// End of quiet hours (hour 0-23).
    quiet_end: u8,
}

/// Reason why a delivery was blocked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeliveryBlock {
    /// Daily budget exhausted.
    BudgetExhausted,
    /// Cooldown period has not elapsed.
    CooldownActive {
        /// Seconds remaining.
        remaining_secs: u64,
    },
    /// Content was already delivered recently.
    Duplicate,
    /// Currently in quiet hours.
    QuietHours,
}

impl NoiseController {
    /// Create a new noise controller with the given budget and cooldown.
    pub fn new(daily_budget: u32, cooldown_secs: u64) -> Self {
        Self {
            daily_budget,
            deliveries_today: 0,
            last_delivery_at: None,
            cooldown_secs,
            recent_hashes: HashSet::new(),
            quiet_start: 23,
            quiet_end: 7,
        }
    }

    /// Set quiet hours (start and end in 24h format).
    #[must_use]
    pub fn with_quiet_hours(mut self, start: u8, end: u8) -> Self {
        self.quiet_start = start.min(23);
        self.quiet_end = end.min(23);
        self
    }

    /// Check whether a delivery should proceed, given the current time and content.
    ///
    /// Returns `Ok(())` if delivery is allowed, or `Err(reason)` if blocked.
    pub fn should_deliver(&self, content_text: &str, now_epoch: u64) -> Result<(), DeliveryBlock> {
        // Check quiet hours.
        if self.is_quiet_hour(now_epoch) {
            return Err(DeliveryBlock::QuietHours);
        }

        // Check budget.
        if self.deliveries_today >= self.daily_budget {
            return Err(DeliveryBlock::BudgetExhausted);
        }

        // Check cooldown.
        if let Some(last) = self.last_delivery_at {
            let elapsed = now_epoch.saturating_sub(last);
            if elapsed < self.cooldown_secs {
                return Err(DeliveryBlock::CooldownActive {
                    remaining_secs: self.cooldown_secs - elapsed,
                });
            }
        }

        // Check dedup.
        let hash = content_hash(content_text);
        if self.recent_hashes.contains(&hash) {
            return Err(DeliveryBlock::Duplicate);
        }

        Ok(())
    }

    /// Record that a delivery was made.
    pub fn record_delivery(&mut self, content_text: &str, now_epoch: u64) {
        self.deliveries_today = self.deliveries_today.saturating_add(1);
        self.last_delivery_at = Some(now_epoch);
        let hash = content_hash(content_text);
        self.recent_hashes.insert(hash);
    }

    /// Reset the daily budget counter (call at midnight or start of day).
    pub fn reset_daily_budget(&mut self) {
        self.deliveries_today = 0;
    }

    /// Clear the dedup set, optionally keeping entries newer than `keep_after_epoch`.
    ///
    /// Since we only store hashes (no timestamps per hash), this clears the
    /// entire set. For time-based pruning, the caller should track timestamps
    /// externally and only call this on a schedule.
    pub fn clear_dedup_set(&mut self) {
        self.recent_hashes.clear();
    }

    /// Returns the number of deliveries remaining today.
    #[must_use]
    pub fn remaining_budget(&self) -> u32 {
        self.daily_budget.saturating_sub(self.deliveries_today)
    }

    /// Returns the current daily budget limit.
    #[must_use]
    pub fn daily_budget(&self) -> u32 {
        self.daily_budget
    }

    /// Returns the number of deliveries made today.
    #[must_use]
    pub fn deliveries_today(&self) -> u32 {
        self.deliveries_today
    }

    /// Check if the given epoch time falls within quiet hours.
    fn is_quiet_hour(&self, now_epoch: u64) -> bool {
        // Convert epoch to hour-of-day (UTC-based, simple for now).
        let hour = ((now_epoch % 86_400) / 3_600) as u8;

        if self.quiet_start <= self.quiet_end {
            // Simple range (e.g. 1:00 to 6:00).
            hour >= self.quiet_start && hour < self.quiet_end
        } else {
            // Wrapping range (e.g. 23:00 to 7:00).
            hour >= self.quiet_start || hour < self.quiet_end
        }
    }
}

/// Compute a content hash for deduplication.
fn content_hash(text: &str) -> u64 {
    let normalized = text.trim().to_lowercase();
    let mut hasher = DefaultHasher::new();
    normalized.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_controller_has_full_budget() {
        let ctrl = NoiseController::new(5, 300);
        assert_eq!(ctrl.remaining_budget(), 5);
        assert_eq!(ctrl.deliveries_today(), 0);
        assert_eq!(ctrl.daily_budget(), 5);
    }

    #[test]
    fn should_deliver_passes_when_conditions_met() {
        let ctrl = NoiseController::new(5, 0).with_quiet_hours(2, 4);
        // 12:00 UTC = hour 12, outside quiet hours.
        let noon = 12 * 3600;
        let result = ctrl.should_deliver("hello", noon);
        assert!(result.is_ok());
    }

    #[test]
    fn budget_enforcement() {
        let mut ctrl = NoiseController::new(2, 0).with_quiet_hours(0, 0);
        let now = 12 * 3600;

        ctrl.record_delivery("first", now);
        assert_eq!(ctrl.remaining_budget(), 1);

        ctrl.record_delivery("second", now);
        assert_eq!(ctrl.remaining_budget(), 0);

        let result = ctrl.should_deliver("third", now);
        assert_eq!(result, Err(DeliveryBlock::BudgetExhausted));
    }

    #[test]
    fn cooldown_enforcement() {
        let mut ctrl = NoiseController::new(10, 300).with_quiet_hours(0, 0);
        let base = 12 * 3600;

        ctrl.record_delivery("msg", base);

        // Too soon (100s later, need 300s).
        let result = ctrl.should_deliver("next", base + 100);
        match result {
            Err(DeliveryBlock::CooldownActive { remaining_secs }) => {
                assert_eq!(remaining_secs, 200);
            }
            other => panic!("expected CooldownActive, got {other:?}"),
        }

        // After cooldown (301s later).
        let result = ctrl.should_deliver("next", base + 301);
        assert!(result.is_ok());
    }

    #[test]
    fn dedup_enforcement() {
        let mut ctrl = NoiseController::new(10, 0).with_quiet_hours(0, 0);
        let now = 12 * 3600;

        ctrl.record_delivery("same message", now);

        let result = ctrl.should_deliver("same message", now + 1);
        assert_eq!(result, Err(DeliveryBlock::Duplicate));

        // Different message passes.
        let result = ctrl.should_deliver("different message", now + 1);
        assert!(result.is_ok());
    }

    #[test]
    fn dedup_is_case_insensitive() {
        let mut ctrl = NoiseController::new(10, 0).with_quiet_hours(0, 0);
        let now = 12 * 3600;

        ctrl.record_delivery("Hello World", now);

        let result = ctrl.should_deliver("hello world", now + 1);
        assert_eq!(result, Err(DeliveryBlock::Duplicate));
    }

    #[test]
    fn quiet_hours_wrapping() {
        // Quiet from 23:00 to 07:00.
        let ctrl = NoiseController::new(10, 0).with_quiet_hours(23, 7);

        // 23:30 UTC → hour 23, in quiet zone.
        let late_night = 23 * 3600 + 1800;
        let result = ctrl.should_deliver("msg", late_night);
        assert_eq!(result, Err(DeliveryBlock::QuietHours));

        // 02:00 UTC → hour 2, in quiet zone.
        let early_morning = 2 * 3600;
        let result = ctrl.should_deliver("msg", early_morning);
        assert_eq!(result, Err(DeliveryBlock::QuietHours));

        // 12:00 UTC → hour 12, outside quiet zone.
        let noon = 12 * 3600;
        let result = ctrl.should_deliver("msg", noon);
        assert!(result.is_ok());
    }

    #[test]
    fn quiet_hours_simple_range() {
        // Quiet from 2:00 to 6:00.
        let ctrl = NoiseController::new(10, 0).with_quiet_hours(2, 6);

        let in_quiet = 3 * 3600;
        let result = ctrl.should_deliver("msg", in_quiet);
        assert_eq!(result, Err(DeliveryBlock::QuietHours));

        let outside = 8 * 3600;
        let result = ctrl.should_deliver("msg", outside);
        assert!(result.is_ok());
    }

    #[test]
    fn reset_daily_budget_restores_capacity() {
        let mut ctrl = NoiseController::new(2, 0).with_quiet_hours(0, 0);
        let now = 12 * 3600;

        ctrl.record_delivery("a", now);
        ctrl.record_delivery("b", now);
        assert_eq!(ctrl.remaining_budget(), 0);

        ctrl.reset_daily_budget();
        assert_eq!(ctrl.remaining_budget(), 2);
        assert_eq!(ctrl.deliveries_today(), 0);
    }

    #[test]
    fn clear_dedup_set_allows_repeat() {
        let mut ctrl = NoiseController::new(10, 0).with_quiet_hours(0, 0);
        let now = 12 * 3600;

        ctrl.record_delivery("msg", now);
        let result = ctrl.should_deliver("msg", now + 1);
        assert_eq!(result, Err(DeliveryBlock::Duplicate));

        ctrl.clear_dedup_set();
        let result = ctrl.should_deliver("msg", now + 1);
        // Still blocked by budget being decremented, but not by dedup.
        // Budget: 10 - 1 = 9, so should pass.
        assert!(result.is_ok());
    }
}
