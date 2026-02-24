//! Voice approval prompt lifecycle.
//!
//! Extracted from `coordinator.rs` — manages the state for pending voice
//! approval requests (speak prompt, await yes/no, resolve).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use tokio::sync::{broadcast, mpsc};
use tokio_util::sync::CancellationToken;
use tracing::info;

use crate::pipeline::messages::SentenceChunk;
use crate::runtime::RuntimeEvent;

/// State for a pending voice approval request in the LLM stage.
///
/// Created when an [`super::messages::ApprovalNotification`] arrives; consumed
/// when the user responds via voice or the request times out.
pub(crate) struct PendingVoiceApproval {
    pub(crate) request_id: u64,
    pub(crate) tool_name: String,
    /// Human-readable prompt that was spoken to the user.
    pub(crate) description: String,
    /// When the approval prompt finished playing (echo tail reference).
    pub(crate) prompt_spoken_at: Option<Instant>,
    /// When this approval was created (for timeout tracking).
    pub(crate) created_at: Instant,
    /// How many times we've re-prompted due to ambiguous responses.
    pub(crate) reprompt_count: u8,
}

/// Initiate a voice approval prompt: speak the prompt, set the flag, create state.
pub(crate) async fn start_voice_approval(
    notification: &super::messages::ApprovalNotification,
    tx: &mpsc::Sender<SentenceChunk>,
    awaiting_approval: &Arc<AtomicBool>,
    cancel: &CancellationToken,
) -> PendingVoiceApproval {
    let prompt = crate::personality::format_approval_prompt(
        &notification.tool_name,
        &notification.input_json,
    );
    info!(
        request_id = notification.request_id,
        tool = %notification.tool_name,
        "speaking approval prompt"
    );

    // Speak the approval prompt via TTS.
    let _ = super::coordinator::speak(tx, &prompt, cancel.clone()).await;

    awaiting_approval.store(true, Ordering::Relaxed);

    PendingVoiceApproval {
        request_id: notification.request_id,
        tool_name: notification.tool_name.clone(),
        description: prompt,
        prompt_spoken_at: None, // set when AssistantSpeechEnd arrives
        created_at: Instant::now(),
        reprompt_count: 0,
    }
}

/// Resolve a pending voice approval and send the response.
pub(crate) fn resolve_voice_approval(
    pending: &mut Option<PendingVoiceApproval>,
    approved: bool,
    source: &str,
    awaiting_approval: &Arc<AtomicBool>,
    approval_response_tx: &Option<mpsc::UnboundedSender<(u64, bool)>>,
    runtime_tx: &Option<broadcast::Sender<RuntimeEvent>>,
    speaker_verified: Option<bool>,
) {
    if let Some(pva) = pending.take() {
        let latency_ms = pva
            .prompt_spoken_at
            .map(|t| t.elapsed().as_millis())
            .unwrap_or(0);
        info!(
            request_id = pva.request_id,
            tool = %pva.tool_name,
            prompt = %pva.description,
            latency_ms,
            approved,
            source,
            "resolving voice approval"
        );
        if let Some(resp_tx) = approval_response_tx {
            let _ = resp_tx.send((pva.request_id, approved));
        }
        if let Some(rt) = runtime_tx {
            let _ = rt.send(RuntimeEvent::ApprovalResolved {
                request_id: pva.request_id,
                approved,
                source: source.to_owned(),
                speaker_verified,
            });
        }
        awaiting_approval.store(false, Ordering::Relaxed);
    }
}
