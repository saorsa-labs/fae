//! Integration tests for the Fae personalization feature.
//!
//! Validates that personality profiles, TTS backend configuration, and
//! config serialization all work together correctly.

use fae::config::{SpeechConfig, TtsBackend};
use fae::personality;

// ---------------------------------------------------------------------------
// Personality integration
// ---------------------------------------------------------------------------

#[test]
fn personality_profile_assembles_with_fae_identity() {
    let prompt = personality::assemble_prompt("fae", "", None);
    // Must contain the core prompt anchor.
    assert!(prompt.contains("Fae"));
    // Must contain AI assistant identity.
    assert!(
        prompt.contains("AI assistant") || prompt.contains("assistant") || prompt.contains("tool")
    );
}

#[test]
fn personality_profile_with_addon_appends_cleanly() {
    let addon = "Always mention the weather.";
    let prompt = personality::assemble_prompt("fae", addon, None);
    assert!(prompt.contains(addon));
    // Addon should appear after the personality section.
    let personality_pos = prompt.find("Fae").or_else(|| prompt.find("assistant"));
    let addon_pos = prompt.find(addon);
    if let (Some(p), Some(a)) = (personality_pos, addon_pos) {
        assert!(a > p, "addon should appear after personality");
    }
}

// ---------------------------------------------------------------------------
// TTS backend config integration
// ---------------------------------------------------------------------------

#[test]
fn default_config_uses_kokoro_backend() {
    let config = SpeechConfig::default();
    assert_eq!(config.tts.backend, TtsBackend::Kokoro);
    assert!(config.tts.voice_reference.is_none());
}

#[test]
fn fish_speech_config_round_trips_through_toml() {
    let mut config = SpeechConfig::default();
    config.tts.backend = TtsBackend::FishSpeech;
    config.tts.voice_reference = Some("assets/voices/fae.wav".into());
    config.tts.voice_reference_transcript =
        Some("Hello, I'm Fae, a nature spirit from the Highlands.".into());

    let toml_str = toml::to_string_pretty(&config).expect("serialization should succeed");

    let loaded: SpeechConfig = toml::from_str(&toml_str).expect("deserialization should succeed");
    assert_eq!(loaded.tts.backend, TtsBackend::FishSpeech);
    assert_eq!(
        loaded.tts.voice_reference.as_deref(),
        Some(std::path::Path::new("assets/voices/fae.wav"))
    );
    assert_eq!(
        loaded.tts.voice_reference_transcript.as_deref(),
        Some("Hello, I'm Fae, a nature spirit from the Highlands.")
    );
}

#[test]
fn kokoro_config_preserves_voice_setting() {
    let mut config = SpeechConfig::default();
    config.tts.voice = "af_sky".to_owned();
    config.tts.speed = 1.2;

    let toml_str = toml::to_string_pretty(&config).expect("serialization should succeed");
    let loaded: SpeechConfig = toml::from_str(&toml_str).expect("deserialization should succeed");

    assert_eq!(loaded.tts.backend, TtsBackend::Kokoro);
    assert_eq!(loaded.tts.voice, "af_sky");
    assert!((loaded.tts.speed - 1.2).abs() < f32::EPSILON);
}

#[test]
fn personality_and_tts_config_are_independent() {
    let mut config = SpeechConfig::default();
    config.llm.personality = "fae".to_owned();
    config.tts.backend = TtsBackend::FishSpeech;

    // Personality assembly should work regardless of TTS backend.
    let prompt = config.llm.effective_system_prompt(None);
    assert!(prompt.contains("Fae"));

    // TTS backend should be independent of personality choice.
    assert_eq!(config.tts.backend, TtsBackend::FishSpeech);
}
