//! Voice identity profile construction and speaker verification.
//!
//! Extracted from `coordinator.rs` — these are pure functions with no
//! pipeline state dependencies.

use std::time::Duration;

use tracing::warn;

use crate::config::{SpeechConfig, VoiceIdentityMode};
use crate::memory::MemoryStore;

/// Cached voice identity profile for the primary user.
#[derive(Debug, Clone)]
pub(crate) struct VoiceIdentityProfile {
    pub(crate) mode: VoiceIdentityMode,
    pub(crate) centroid: Option<Vec<f32>>,
    pub(crate) threshold_accept: f32,
    pub(crate) threshold_hold: f32,
    pub(crate) hold_window: Duration,
}

impl VoiceIdentityProfile {
    pub(crate) fn is_enrolled(&self) -> bool {
        self.centroid.is_some()
    }

    pub(crate) fn similarity(&self, sample: Option<&Vec<f32>>) -> Option<f32> {
        let centroid = self.centroid.as_ref()?;
        let sample = sample?;
        crate::voiceprint::similarity(sample, centroid)
    }
}

/// Extract all voiceprint enrollment samples from a primary user record.
pub(crate) fn extract_voiceprint_samples(user: &crate::memory::PrimaryUser) -> Vec<Vec<f32>> {
    let mut samples = user.voiceprints.clone();
    if samples.is_empty()
        && let Some(v) = user.voiceprint.clone()
    {
        samples.push(v);
    }
    samples
}

/// Build a [`VoiceIdentityProfile`] from the primary user and config.
pub(crate) fn build_voice_identity_profile(
    user: Option<&crate::memory::PrimaryUser>,
    config: &crate::config::VoiceIdentityConfig,
) -> VoiceIdentityProfile {
    let mut threshold_accept = config.threshold_accept.clamp(-1.0, 1.0);
    let mut threshold_hold = config.threshold_hold.clamp(-1.0, 1.0);
    if threshold_hold > threshold_accept {
        std::mem::swap(&mut threshold_hold, &mut threshold_accept);
    }

    let required_samples = config.min_enroll_samples.max(1) as usize;
    let centroid = user.and_then(|u| {
        if let Some(c) = u.voiceprint_centroid.clone() {
            return Some(c);
        }
        if let Some(v) = u.voiceprint.clone() {
            return Some(v);
        }
        let samples = extract_voiceprint_samples(u);
        if samples.len() >= required_samples {
            crate::voiceprint::centroid(&samples)
        } else {
            None
        }
    });

    VoiceIdentityProfile {
        mode: config.mode,
        centroid,
        threshold_accept,
        threshold_hold,
        hold_window: Duration::from_secs(config.hold_window_s as u64),
    }
}

/// Check whether a transcription passes speaker verification against the
/// approval voice profile.
///
/// Returns `(verified, similarity_score)`. If no profile is provided,
/// verification is considered passed.
pub(crate) fn approval_speaker_verified(
    profile: Option<&VoiceIdentityProfile>,
    transcription: &crate::pipeline::messages::Transcription,
) -> (bool, Option<f32>) {
    let Some(profile) = profile else {
        return (true, None);
    };
    let similarity = profile.similarity(transcription.voiceprint.as_ref());
    let verified = similarity.is_some_and(|s| s >= profile.threshold_accept);
    (verified, similarity)
}

/// Load the voice identity profile for approval speaker matching.
///
/// Returns `None` if voice identity is disabled, approval matching is off,
/// or the user is not enrolled.
pub(crate) fn load_approval_voice_profile(config: &SpeechConfig) -> Option<VoiceIdentityProfile> {
    if !(config.voice_identity.enabled && config.voice_identity.approval_requires_match) {
        return None;
    }
    let store = MemoryStore::new(&config.memory.root_dir);
    let user = match store.load_primary_user() {
        Ok(u) => u,
        Err(e) => {
            warn!("failed to load primary user for approval voice match: {e}");
            return None;
        }
    };
    let profile = build_voice_identity_profile(user.as_ref(), &config.voice_identity);
    if profile.is_enrolled() {
        Some(profile)
    } else {
        None
    }
}
