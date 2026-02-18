//! End-to-end integration tests for the local Chatterbox TTS server.
//!
//! These tests require a running Chatterbox server at `http://127.0.0.1:8000`
//! and are gated behind the `chatterbox` feature flag so they never run in CI.
//!
//! To run:
//! ```bash
//! cargo test --features chatterbox
//! ```

#![cfg(feature = "chatterbox")]

/// Check that a local Chatterbox server is reachable. Returns the client on
/// success; on failure the invoking test returns early (skips) instead of
/// aborting the entire process.
macro_rules! require_chatterbox {
    () => {{
        let client = reqwest::Client::new();
        match client.get("http://127.0.0.1:8000/health").send().await {
            Ok(resp) if resp.status().is_success() => client,
            _ => {
                eprintln!("chatterbox server not running — skipping test");
                return;
            }
        }
    }};
}

#[tokio::test]
async fn e2e_chatterbox_health() {
    let client = require_chatterbox!();

    let resp = client
        .get("http://127.0.0.1:8000/health")
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn e2e_chatterbox_synthesize_wav() {
    let client = require_chatterbox!();

    let resp = client
        .post("http://127.0.0.1:8000/synthesize")
        .json(&serde_json::json!({"text": "Hello from Fae test suite"}))
        .send()
        .await
        .unwrap();

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
}

#[tokio::test]
async fn e2e_chatterbox_speak() {
    let client = require_chatterbox!();

    let resp = client
        .post("http://127.0.0.1:8000/speak")
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
        .get("http://127.0.0.1:8000/voices")
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
        .post("http://127.0.0.1:8000/v1/text-to-speech/default")
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
