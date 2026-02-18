//! Onboarding state machine for the Fae first-run experience.
//!
//! The onboarding flow has four phases:
//!
//! ```text
//! Welcome → Permissions → Ready → Complete
//! ```
//!
//! The current phase is persisted in [`crate::config::SpeechConfig`] and
//! exposed to the Swift shell via the `onboarding.get_state`,
//! `onboarding.advance`, and `onboarding.complete` host commands.

use serde::{Deserialize, Serialize};
use std::fmt;

/// The four phases of the Fae onboarding experience.
///
/// Phases advance in order: Welcome → Permissions → Ready → Complete.
/// Calling `onboarding.complete` jumps directly to `Complete` from any phase
/// and also sets `config.onboarded = true`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum OnboardingPhase {
    /// Initial welcome screen — introduces Fae and the onboarding flow.
    #[default]
    Welcome,
    /// Permissions screen — user grants microphone, contacts, etc.
    Permissions,
    /// Ready screen — personalised greeting and listening indicator.
    Ready,
    /// Onboarding complete — user has finished the flow.
    Complete,
}

impl OnboardingPhase {
    /// Advance to the next phase in the sequence.
    ///
    /// Returns `Some(next)` unless already at `Complete`, in which case
    /// returns `None`.
    ///
    /// # Examples
    ///
    /// ```
    /// use fae::onboarding::OnboardingPhase;
    ///
    /// assert_eq!(OnboardingPhase::Welcome.advance(), Some(OnboardingPhase::Permissions));
    /// assert_eq!(OnboardingPhase::Complete.advance(), None);
    /// ```
    #[must_use]
    pub fn advance(self) -> Option<Self> {
        match self {
            Self::Welcome => Some(Self::Permissions),
            Self::Permissions => Some(Self::Ready),
            Self::Ready => Some(Self::Complete),
            Self::Complete => None,
        }
    }

    /// Return the canonical wire-format string for this phase.
    ///
    /// # Examples
    ///
    /// ```
    /// use fae::onboarding::OnboardingPhase;
    ///
    /// assert_eq!(OnboardingPhase::Welcome.as_str(), "welcome");
    /// assert_eq!(OnboardingPhase::Complete.as_str(), "complete");
    /// ```
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Welcome => "welcome",
            Self::Permissions => "permissions",
            Self::Ready => "ready",
            Self::Complete => "complete",
        }
    }

    /// Parse a phase from its wire-format string.
    ///
    /// Returns `None` if the input does not match any known phase.
    ///
    /// # Examples
    ///
    /// ```
    /// use fae::onboarding::OnboardingPhase;
    ///
    /// assert_eq!(OnboardingPhase::parse("welcome"), Some(OnboardingPhase::Welcome));
    /// assert_eq!(OnboardingPhase::parse("unknown"), None);
    /// ```
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "welcome" => Some(Self::Welcome),
            "permissions" => Some(Self::Permissions),
            "ready" => Some(Self::Ready),
            "complete" => Some(Self::Complete),
            _ => None,
        }
    }
}

impl fmt::Display for OnboardingPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advance_welcome_yields_permissions() {
        assert_eq!(
            OnboardingPhase::Welcome.advance(),
            Some(OnboardingPhase::Permissions)
        );
    }

    #[test]
    fn advance_permissions_yields_ready() {
        assert_eq!(
            OnboardingPhase::Permissions.advance(),
            Some(OnboardingPhase::Ready)
        );
    }

    #[test]
    fn advance_ready_yields_complete() {
        assert_eq!(
            OnboardingPhase::Ready.advance(),
            Some(OnboardingPhase::Complete)
        );
    }

    #[test]
    fn advance_complete_yields_none() {
        assert_eq!(OnboardingPhase::Complete.advance(), None);
    }

    #[test]
    fn serde_roundtrip_for_all_phases() {
        for phase in [
            OnboardingPhase::Welcome,
            OnboardingPhase::Permissions,
            OnboardingPhase::Ready,
            OnboardingPhase::Complete,
        ] {
            let json = serde_json::to_value(phase).expect("serialize phase");
            let back: OnboardingPhase =
                serde_json::from_value(json.clone()).expect("deserialize phase");
            assert_eq!(back, phase, "serde roundtrip failed for {json}");
        }
    }

    #[test]
    fn as_str_and_parse_roundtrip() {
        for phase in [
            OnboardingPhase::Welcome,
            OnboardingPhase::Permissions,
            OnboardingPhase::Ready,
            OnboardingPhase::Complete,
        ] {
            let wire = phase.as_str();
            let parsed = OnboardingPhase::parse(wire)
                .unwrap_or_else(|| panic!("failed to parse wire format `{wire}`"));
            assert_eq!(parsed, phase);
        }
    }
}
