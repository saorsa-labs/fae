//! End-to-end integration tests for the local Chatterbox TTS server.
//!
//! These tests require a running Chatterbox server at `http://127.0.0.1:8004`
//! and are gated behind the `chatterbox` feature flag so they never run in CI.
//!
//! To run:
//! ```bash
//! cargo test --features chatterbox
//! ```

/// Chatterbox server base URL (port 8004).
const CHATTERBOX_BASE: &str = "http://127.0.0.1:8004";

/// Check that a local Chatterbox server is reachable. Returns the client on
/// success; on failure the invoking test returns early (skips) instead of
/// aborting the entire process.
macro_rules! require_chatterbox {
    () => {{
        let client = reqwest::Client::new();
        match client
            .get(format!("{}/health", CHATTERBOX_BASE))
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => client,
            _ => {
                eprintln!("chatterbox server not running at {CHATTERBOX_BASE} — skipping test");
                return;
            }
        }
    }};
}

#[tokio::test]
async fn e2e_chatterbox_health() {
    let client = require_chatterbox!();

    let resp = client
        .get(format!("{CHATTERBOX_BASE}/health"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn e2e_chatterbox_synthesize_wav() {
    let client = require_chatterbox!();

    let start = std::time::Instant::now();
    let resp = client
        .post(format!("{CHATTERBOX_BASE}/synthesize"))
        .json(&serde_json::json!({"text": "Hello from Fae test suite"}))
        .send()
        .await
        .unwrap();
    let elapsed = start.elapsed();

    assert!(resp.status().is_success());

    let body = resp.bytes().await.unwrap();

    // A valid WAV file begins with the ASCII bytes "RIFF".
    assert!(
        body.len() > 44,
        "WAV payload too small ({} bytes)",
        body.len()
    );
    assert_eq!(
        &body[..4],
        b"RIFF",
        "response does not start with RIFF header"
    );

    eprintln!(
        "TTS latency: {}ms for {} bytes ({} chars input)",
        elapsed.as_millis(),
        body.len(),
        "Hello from Fae test suite".len()
    );
}

#[tokio::test]
async fn e2e_chatterbox_speak() {
    let client = require_chatterbox!();

    let resp = client
        .post(format!("{CHATTERBOX_BASE}/speak"))
        .json(&serde_json::json!({"text": "Test utterance", "play": false}))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn e2e_chatterbox_list_voices() {
    let client = require_chatterbox!();

    let resp = client
        .get(format!("{CHATTERBOX_BASE}/voices"))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());

    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(
        body.is_array(),
        "expected JSON array from /voices, got: {body}"
    );
}

#[tokio::test]
async fn e2e_chatterbox_elevenlabs_compat() {
    let client = require_chatterbox!();

    let resp = client
        .post(format!("{CHATTERBOX_BASE}/v1/text-to-speech/default"))
        .json(&serde_json::json!({"text": "ElevenLabs compatibility test"}))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());

    let body = resp.bytes().await.unwrap();

    assert!(
        body.len() > 44,
        "WAV payload too small ({} bytes)",
        body.len()
    );
    assert_eq!(
        &body[..4],
        b"RIFF",
        "response does not start with RIFF header"
    );
}

/// Measure round-trip TTS latency for varying sentence lengths.
///
/// This test synthesizes sentences of increasing length and reports the
/// latency and audio duration for each, helping identify where the TTS
/// latency scales non-linearly.
#[tokio::test]
async fn e2e_chatterbox_latency_profile() {
    let client = require_chatterbox!();

    let sentences = [
        "Hi.",
        "Hello, how are you today?",
        "I'd be happy to help you with that request.",
        "Let me think about this for a moment and get back to you with a thoughtful response.",
        "The quick brown fox jumps over the lazy dog, and then proceeds to run through the forest at remarkable speed while the dog watches.",
    ];

    eprintln!("\n--- Chatterbox TTS Latency Profile ---");
    eprintln!(
        "{:<6} {:<10} {:<12} {:<10}",
        "Chars", "Latency", "Audio Dur", "RTF"
    );

    for text in &sentences {
        let start = std::time::Instant::now();
        let resp = client
            .post(format!("{CHATTERBOX_BASE}/synthesize"))
            .json(&serde_json::json!({"text": text}))
            .send()
            .await
            .unwrap();
        let elapsed = start.elapsed();

        assert!(resp.status().is_success());

        let body = resp.bytes().await.unwrap();
        assert!(body.len() > 44);

        // Parse WAV header to estimate audio duration.
        // WAV format: bytes 24-27 = sample rate, bytes 34-35 = bits per sample
        // data chunk starts at byte 44, so audio bytes = len - 44
        let sample_rate = if body.len() >= 28 {
            u32::from_le_bytes([body[24], body[25], body[26], body[27]])
        } else {
            24000
        };
        let bits_per_sample = if body.len() >= 36 {
            u16::from_le_bytes([body[34], body[35]])
        } else {
            16
        };
        let audio_bytes = body.len().saturating_sub(44);
        let bytes_per_sample = (bits_per_sample / 8) as usize;
        let total_samples = if bytes_per_sample > 0 {
            audio_bytes / bytes_per_sample
        } else {
            0
        };
        let audio_duration_ms = if sample_rate > 0 {
            (total_samples as f64 / sample_rate as f64) * 1000.0
        } else {
            0.0
        };

        // Real-time factor: latency / audio duration (< 1.0 means faster than real-time)
        let rtf = if audio_duration_ms > 0.0 {
            elapsed.as_millis() as f64 / audio_duration_ms
        } else {
            f64::INFINITY
        };

        eprintln!(
            "{:<6} {:<10} {:<12} {:<10.2}",
            text.len(),
            format!("{}ms", elapsed.as_millis()),
            format!("{:.0}ms", audio_duration_ms),
            rtf
        );
    }
    eprintln!("--------------------------------------\n");
}
