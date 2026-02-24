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

/// Shared state references needed by approval resolution and advancement.
///
/// Bundles the channel/flag references that are always passed together to avoid
/// excessive parameter counts on approval helper functions.
pub(crate) struct ApprovalContext<'a> {
    pub(crate) pending: &'a mut Option<PendingVoiceApproval>,
    pub(crate) ack_counter: &'a mut u64,
    pub(crate) awaiting_approval: &'a Arc<AtomicBool>,
    pub(crate) approval_response_tx: &'a Option<mpsc::UnboundedSender<(u64, bool)>>,
    pub(crate) runtime_tx: &'a Option<broadcast::Sender<RuntimeEvent>>,
    pub(crate) queue: &'a mut Vec<super::messages::ApprovalNotification>,
    pub(crate) tx: &'a mpsc::Sender<SentenceChunk>,
    pub(crate) cancel: &'a CancellationToken,
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

/// Resolve a pending approval, speak the acknowledgment, and advance to the
/// next queued approval (if any).
///
/// This consolidates the repeated resolve-ack-queue-pop pattern that appears
/// for every approval resolution path (Approved, Denied, Ambiguous max, Timeout).
pub(crate) async fn resolve_and_advance_approval(
    ctx: &mut ApprovalContext<'_>,
    ack_list: &[&str],
    approved: bool,
    source: &str,
    speaker_verified: Option<bool>,
) {
    let ack = crate::personality::next_acknowledgment(ack_list, *ctx.ack_counter);
    *ctx.ack_counter += 1;
    resolve_voice_approval(
        ctx.pending,
        approved,
        source,
        ctx.awaiting_approval,
        ctx.approval_response_tx,
        ctx.runtime_tx,
        speaker_verified,
    );
    let _ = ctx
        .tx
        .send(SentenceChunk {
            text: ack.to_owned(),
            is_final: true,
        })
        .await;
    if let Some(next) = ctx.queue.pop() {
        *ctx.pending =
            Some(start_voice_approval(&next, ctx.tx, ctx.awaiting_approval, ctx.cancel).await);
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
