//! Bounded queue for user inputs received while an LLM run is active.
//!
//! Extracted from `coordinator.rs` — these types and helpers manage the
//! pending-input queue between the transcription/injection stages and the
//! LLM generation stage.

use std::collections::VecDeque;

use tokio::sync::mpsc;
use tracing::warn;

use crate::config::{LlmMessageQueueDropPolicy, LlmMessageQueueMode};
use crate::pipeline::messages::{TextInjection, Transcription};

/// A user input item pending for the LLM stage.
#[derive(Debug, Clone)]
pub(crate) enum QueuedLlmInput {
    Transcription(Transcription),
    TextInjection(TextInjection),
}

impl QueuedLlmInput {
    pub(crate) fn text(&self) -> &str {
        match self {
            Self::Transcription(t) => &t.text,
            Self::TextInjection(i) => &i.text,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum QueueEnqueueAction {
    Enqueued,
    DroppedOldest,
    DroppedNewest,
    DroppedIncoming,
}

/// Bounded queue for user inputs received while an LLM run is active.
pub(crate) struct LlmInputQueue {
    mode: LlmMessageQueueMode,
    max_pending: usize,
    drop_policy: LlmMessageQueueDropPolicy,
    pending: VecDeque<QueuedLlmInput>,
}

impl LlmInputQueue {
    pub(crate) fn new(config: &crate::config::LlmConfig) -> Self {
        Self {
            mode: config.message_queue_mode,
            max_pending: config.message_queue_max_pending,
            drop_policy: config.message_queue_drop_policy,
            pending: VecDeque::new(),
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.pending.len()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    pub(crate) fn clear(&mut self) -> usize {
        let cleared = self.pending.len();
        self.pending.clear();
        cleared
    }

    pub(crate) fn enqueue(&mut self, input: QueuedLlmInput) -> QueueEnqueueAction {
        if input.text().trim().is_empty() {
            return QueueEnqueueAction::DroppedIncoming;
        }

        if self.max_pending == 0 {
            return QueueEnqueueAction::DroppedIncoming;
        }

        if self.pending.len() < self.max_pending {
            self.pending.push_back(input);
            return QueueEnqueueAction::Enqueued;
        }

        match self.drop_policy {
            LlmMessageQueueDropPolicy::Oldest => {
                let _ = self.pending.pop_front();
                self.pending.push_back(input);
                QueueEnqueueAction::DroppedOldest
            }
            LlmMessageQueueDropPolicy::Newest => {
                let _ = self.pending.pop_back();
                self.pending.push_back(input);
                QueueEnqueueAction::DroppedNewest
            }
            LlmMessageQueueDropPolicy::None => QueueEnqueueAction::DroppedIncoming,
        }
    }

    pub(crate) fn dequeue_next(&mut self) -> Option<QueuedLlmInput> {
        match self.mode {
            LlmMessageQueueMode::Followup => self.pending.pop_front(),
            LlmMessageQueueMode::Collect => self.dequeue_collect_mode(),
        }
    }

    fn dequeue_collect_mode(&mut self) -> Option<QueuedLlmInput> {
        let first = self.pending.pop_front()?;
        match first {
            QueuedLlmInput::Transcription(mut merged) => {
                while let Some(QueuedLlmInput::Transcription(next)) = self.pending.front() {
                    if next.text.trim().is_empty() {
                        let _ = self.pending.pop_front();
                        continue;
                    }
                    let Some(QueuedLlmInput::Transcription(next)) = self.pending.pop_front() else {
                        break;
                    };
                    append_collected_text(&mut merged.text, &next.text);
                    merged.is_final = merged.is_final || next.is_final;
                    merged.transcribed_at = next.transcribed_at;
                }
                Some(QueuedLlmInput::Transcription(merged))
            }
            QueuedLlmInput::TextInjection(mut merged) => {
                if merged.fork_at_keep_count.is_some() {
                    return Some(QueuedLlmInput::TextInjection(merged));
                }
                while let Some(QueuedLlmInput::TextInjection(next)) = self.pending.front() {
                    if next.fork_at_keep_count.is_some() {
                        break;
                    }
                    if next.text.trim().is_empty() {
                        let _ = self.pending.pop_front();
                        continue;
                    }
                    let Some(QueuedLlmInput::TextInjection(next)) = self.pending.pop_front() else {
                        break;
                    };
                    append_collected_text(&mut merged.text, &next.text);
                }
                Some(QueuedLlmInput::TextInjection(merged))
            }
        }
    }
}

fn append_collected_text(base: &mut String, next: &str) {
    let next = next.trim();
    if next.is_empty() {
        return;
    }
    if !base.trim().is_empty() {
        base.push_str("\n\n");
    } else {
        base.clear();
    }
    base.push_str(next);
}

/// Log-and-enqueue a user input into the pending queue.
pub(crate) fn enqueue_pending_input(queue: &mut LlmInputQueue, input: QueuedLlmInput) {
    let action = queue.enqueue(input);
    match action {
        QueueEnqueueAction::Enqueued => {}
        QueueEnqueueAction::DroppedOldest => {
            warn!(
                pending = queue.len(),
                "LLM pending-input queue full, dropped oldest entry"
            );
        }
        QueueEnqueueAction::DroppedNewest => {
            warn!(
                pending = queue.len(),
                "LLM pending-input queue full, dropped newest queued entry"
            );
        }
        QueueEnqueueAction::DroppedIncoming => {
            warn!(
                pending = queue.len(),
                "LLM pending-input queue full, dropped incoming entry"
            );
        }
    }
}

/// Drain all pending inputs from both the queue and the raw channels.
pub(crate) fn clear_pending_inputs(
    queue: &mut LlmInputQueue,
    rx: &mut mpsc::Receiver<Transcription>,
    text_injection_rx: &mut Option<mpsc::UnboundedReceiver<TextInjection>>,
    transcription_channel_closed: &mut bool,
) -> usize {
    let mut cleared = queue.clear();

    loop {
        match rx.try_recv() {
            Ok(t) => {
                if !t.text.trim().is_empty() {
                    cleared += 1;
                }
            }
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
            Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                *transcription_channel_closed = true;
                break;
            }
        }
    }

    if let Some(injection_rx) = text_injection_rx.as_mut() {
        loop {
            match injection_rx.try_recv() {
                Ok(injection) => {
                    if !injection.text.trim().is_empty() {
                        cleared += 1;
                    }
                }
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    *text_injection_rx = None;
                    break;
                }
            }
        }
    }

    cleared
}
