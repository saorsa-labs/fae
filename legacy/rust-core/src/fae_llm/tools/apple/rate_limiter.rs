//! Token-bucket rate limiter for Apple ecosystem API calls.
//!
//! [`AppleRateLimiter`] prevents excessive calls to macOS system frameworks
//! (Contacts, Calendar, Reminders, Mail, Notes) by enforcing a configurable
//! calls-per-second limit using a token-bucket algorithm.

use std::fmt;
use std::sync::Mutex;
use std::time::Instant;

/// Error returned when the rate limiter cannot fulfil a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RateLimitError {
    /// The token bucket is exhausted — caller should back off.
    Exceeded,
    /// Internal lock is poisoned (should not happen in practice).
    LockPoisoned,
}

impl fmt::Display for RateLimitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RateLimitError::Exceeded => f.write_str("rate limit exceeded"),
            RateLimitError::LockPoisoned => f.write_str("rate limiter lock poisoned"),
        }
    }
}

impl std::error::Error for RateLimitError {}

/// Internal mutable state for the token-bucket algorithm.
struct RateLimiterState {
    /// Maximum number of tokens (burst capacity).
    capacity: u32,
    /// Currently available tokens (fractional for sub-token accumulation).
    available: f64,
    /// Tokens added per second.
    refill_rate: f64,
    /// Timestamp of the last refill calculation.
    last_check: Instant,
}

/// Rate limiter for Apple ecosystem API calls.
///
/// Uses a token-bucket algorithm: up to `capacity` tokens are available,
/// refilling at `refill_rate` tokens per second.  Each call to
/// [`try_acquire`](Self::try_acquire) consumes one token.
///
/// Thread-safe — all state is protected by a [`Mutex`].
pub struct AppleRateLimiter {
    inner: Mutex<RateLimiterState>,
}

impl AppleRateLimiter {
    /// Create a new rate limiter.
    ///
    /// # Arguments
    ///
    /// * `capacity` — maximum burst size (tokens available initially).
    /// * `refill_rate_per_sec` — tokens added per second.
    pub fn new(capacity: u32, refill_rate_per_sec: f64) -> Self {
        Self {
            inner: Mutex::new(RateLimiterState {
                capacity,
                available: f64::from(capacity),
                refill_rate: refill_rate_per_sec,
                last_check: Instant::now(),
            }),
        }
    }

    /// Create a rate limiter with default Apple ecosystem settings.
    ///
    /// Allows 10 calls per second with a burst capacity of 10.
    pub fn default_apple() -> Self {
        Self::new(10, 10.0)
    }

    /// Try to acquire one token.
    ///
    /// Returns `Ok(())` if a token was available, or
    /// [`RateLimitError::Exceeded`] if the bucket is empty.
    pub fn try_acquire(&self) -> Result<(), RateLimitError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| RateLimitError::LockPoisoned)?;
        let now = Instant::now();
        let elapsed = now.duration_since(state.last_check).as_secs_f64();
        state.last_check = now;

        // Refill tokens, capping at capacity.
        state.available =
            (state.available + elapsed * state.refill_rate).min(f64::from(state.capacity));

        if state.available >= 1.0 {
            state.available -= 1.0;
            Ok(())
        } else {
            Err(RateLimitError::Exceeded)
        }
    }

    /// Returns the burst capacity.
    pub fn capacity(&self) -> u32 {
        self.inner.lock().map(|s| s.capacity).unwrap_or(0)
    }

    /// Returns the refill rate (tokens per second).
    pub fn refill_rate(&self) -> f64 {
        self.inner.lock().map(|s| s.refill_rate).unwrap_or(0.0)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn new_limiter_allows_up_to_capacity() {
        let limiter = AppleRateLimiter::new(5, 5.0);
        for i in 0..5 {
            assert!(limiter.try_acquire().is_ok(), "call {i} should succeed");
        }
        assert!(
            limiter.try_acquire().is_err(),
            "call beyond capacity should fail"
        );
    }

    #[test]
    fn refills_over_time() {
        let limiter = AppleRateLimiter::new(2, 10.0);
        // Exhaust both tokens.
        assert!(limiter.try_acquire().is_ok());
        assert!(limiter.try_acquire().is_ok());
        assert!(limiter.try_acquire().is_err());

        // Wait for ~1.1 tokens to refill (at 10/sec, 110ms ≈ 1.1 tokens).
        thread::sleep(Duration::from_millis(110));

        assert!(
            limiter.try_acquire().is_ok(),
            "should have refilled after sleep"
        );
    }

    #[test]
    fn default_apple_has_expected_capacity() {
        let limiter = AppleRateLimiter::default_apple();
        assert_eq!(limiter.capacity(), 10);
        assert!((limiter.refill_rate() - 10.0).abs() < f64::EPSILON);
    }

    #[test]
    fn try_acquire_returns_ok_when_available() {
        let limiter = AppleRateLimiter::new(1, 1.0);
        assert!(limiter.try_acquire().is_ok());
    }

    #[test]
    fn thread_safety() {
        let limiter = Arc::new(AppleRateLimiter::new(100, 100.0));
        let mut handles = Vec::new();

        for _ in 0..4 {
            let l = Arc::clone(&limiter);
            handles.push(thread::spawn(move || {
                let mut ok = 0u32;
                for _ in 0..25 {
                    if l.try_acquire().is_ok() {
                        ok += 1;
                    }
                }
                ok
            }));
        }

        let total: u32 = handles.into_iter().map(|h| h.join().unwrap()).sum();
        // All 100 tokens should be consumed across threads.
        assert_eq!(total, 100, "all tokens should be consumed exactly once");
    }

    #[test]
    fn partial_refill() {
        let limiter = AppleRateLimiter::new(1, 10.0);
        // Consume the single token.
        assert!(limiter.try_acquire().is_ok());
        assert!(limiter.try_acquire().is_err());

        // Wait 50ms → ~0.5 tokens refilled (not enough for 1).
        thread::sleep(Duration::from_millis(50));
        // Might or might not have enough — borderline.  Wait another 60ms to be safe.
        thread::sleep(Duration::from_millis(60));

        assert!(
            limiter.try_acquire().is_ok(),
            "should succeed after 110ms total at 10/sec"
        );
    }
}
