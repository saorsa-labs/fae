//! Message types passed between pipeline stages.

use std::time::Instant;
use tokio::sync::oneshot;

/// Control events emitted by stages to coordinate interruption and UI state.
#[derive(Debug, Clone)]
pub enum ControlEvent {
    /// VAD detected the start of user speech (barge-in signal).
    UserSpeechStart {
        /// Timestamp for the chunk that triggered speech start.
        captured_at: Instant,
        /// RMS energy of the triggering chunk.
        rms: f32,
    },
    /// Assistant playback started (first non-empty audio queued).
    AssistantSpeechStart,
    /// Assistant playback ended (response completed).
    AssistantSpeechEnd {
        /// Whether playback ended due to interruption.
        interrupted: bool,
    },
    /// MFCC+DTW wake word spotter detected the keyword in raw audio.
    WakewordDetected,
}

/// A chunk of raw audio samples from the microphone.
#[derive(Debug, Clone)]
pub struct AudioChunk {
    /// Interleaved f32 samples, mono, at the configured input sample rate.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Timestamp when this chunk was captured.
    pub captured_at: Instant,
}

/// A complete speech segment detected by VAD, ready for STT.
#[derive(Debug, Clone)]
pub struct SpeechSegment {
    /// Concatenated audio samples for the entire utterance.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// When the speech segment started.
    pub started_at: Instant,
}

/// A transcription result from the STT engine.
#[derive(Debug, Clone)]
pub struct Transcription {
    /// The transcribed text.
    pub text: String,
    /// Whether this is a final transcription (vs partial/streaming).
    pub is_final: bool,
    /// Optional voiceprint features for best-effort speaker matching.
    ///
    /// This is computed from the original audio and is intended for lightweight
    /// "respond mostly to the primary user" behavior.
    pub voiceprint: Option<Vec<f32>>,
    /// Time the original audio was captured.
    pub audio_captured_at: Instant,
    /// Time the transcription completed.
    pub transcribed_at: Instant,
}

/// A single token emitted by the LLM during streaming generation.
#[derive(Debug, Clone)]
pub struct LlmToken {
    /// The decoded text fragment.
    pub text: String,
    /// Whether this is the final token in the response.
    pub is_end: bool,
}

/// A sentence accumulated from LLM tokens, ready for TTS.
#[derive(Debug, Clone)]
pub struct SentenceChunk {
    /// Complete sentence text.
    pub text: String,
    /// Whether this is the last sentence in the response.
    pub is_final: bool,
}

/// A text message injected directly from the GUI, bypassing STT.
#[derive(Debug, Clone)]
pub struct TextInjection {
    /// The user's typed text.
    pub text: String,
    /// If `Some`, truncate LLM history to keep only this many entries
    /// (system prompt + N user/assistant pairs) before injecting.
    pub fork_at_keep_count: Option<usize>,
}

/// Commands sent from the GUI to the conversation gate.
#[derive(Debug, Clone)]
pub enum GateCommand {
    /// Activate the gate (equivalent to wake word).
    Wake,
    /// Deactivate the gate (equivalent to stop phrase).
    Sleep,
}

/// Synthesized audio from TTS, ready for playback.
#[derive(Debug, Clone)]
pub struct SynthesizedAudio {
    /// f32 audio samples.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Whether this is the last chunk of the current response.
    pub is_final: bool,
}

/// A conversation request from the scheduler to the pipeline.
///
/// Scheduled tasks can trigger conversations by sending this message.
/// The pipeline processes the prompt and returns the result via the response channel.
#[derive(Debug)]
pub struct ConversationRequest {
    /// The scheduled task ID that triggered this conversation.
    pub task_id: String,
    /// The user prompt to inject into the conversation.
    pub prompt: String,
    /// Optional addition to the system prompt for this conversation.
    pub system_addon: Option<String>,
    /// Timeout in seconds for this conversation. Defaults to 300s if None.
    pub timeout_secs: Option<u64>,
    /// Channel for sending the conversation result back to the scheduler.
    pub response_tx: oneshot::Sender<ConversationResponse>,
}

/// The result of a scheduler-triggered conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConversationResponse {
    /// Conversation completed successfully with this response text.
    Success(String),
    /// Conversation failed with this error message.
    Error(String),
    /// Conversation exceeded the timeout limit.
    Timeout,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_request_created() {
        let (tx, _rx) = oneshot::channel();
        let request = ConversationRequest {
            task_id: "reminder_123".to_owned(),
            prompt: "Check my calendar".to_owned(),
            system_addon: Some("You are a calendar assistant".to_owned()),
            timeout_secs: Some(120),
            response_tx: tx,
        };

        assert_eq!(request.task_id, "reminder_123");
        assert_eq!(request.prompt, "Check my calendar");
        match request.system_addon {
            Some(ref addon) => assert_eq!(addon, "You are a calendar assistant"),
            None => unreachable!(),
        }
        assert_eq!(request.timeout_secs, Some(120));
    }

    #[test]
    fn conversation_request_minimal() {
        let (tx, _rx) = oneshot::channel();
        let request = ConversationRequest {
            task_id: "task_1".to_owned(),
            prompt: "Simple prompt".to_owned(),
            system_addon: None,
            timeout_secs: None,
            response_tx: tx,
        };

        assert_eq!(request.task_id, "task_1");
        assert_eq!(request.prompt, "Simple prompt");
        assert!(request.system_addon.is_none());
        assert!(request.timeout_secs.is_none());
    }

    #[test]
    fn conversation_response_success() {
        let response = ConversationResponse::Success("Task complete".to_owned());
        match response {
            ConversationResponse::Success(msg) => assert_eq!(msg, "Task complete"),
            _ => unreachable!(),
        }
    }

    #[test]
    fn conversation_response_error() {
        let response = ConversationResponse::Error("LLM failed".to_owned());
        match response {
            ConversationResponse::Error(msg) => assert_eq!(msg, "LLM failed"),
            _ => unreachable!(),
        }
    }

    #[test]
    fn conversation_response_timeout() {
        let response = ConversationResponse::Timeout;
        assert_eq!(response, ConversationResponse::Timeout);
    }

    #[test]
    fn conversation_response_equality() {
        assert_eq!(
            ConversationResponse::Success("test".to_owned()),
            ConversationResponse::Success("test".to_owned())
        );
        assert_eq!(
            ConversationResponse::Error("err".to_owned()),
            ConversationResponse::Error("err".to_owned())
        );
        assert_eq!(ConversationResponse::Timeout, ConversationResponse::Timeout);

        assert_ne!(
            ConversationResponse::Success("a".to_owned()),
            ConversationResponse::Success("b".to_owned())
        );
        assert_ne!(
            ConversationResponse::Success("x".to_owned()),
            ConversationResponse::Error("x".to_owned())
        );
    }

    #[tokio::test]
    async fn conversation_channel_send_receive() {
        let (tx, rx) = oneshot::channel();
        let _request = ConversationRequest {
            task_id: "test".to_owned(),
            prompt: "test prompt".to_owned(),
            system_addon: None,
            timeout_secs: None,
            response_tx: tx,
        };

        // Simulate sending response
        let send_result = _request
            .response_tx
            .send(ConversationResponse::Success("done".to_owned()));
        assert!(send_result.is_ok());

        // Receive response
        let received = rx.await.expect("receive");
        assert_eq!(received, ConversationResponse::Success("done".to_owned()));
    }

    #[tokio::test]
    async fn conversation_channel_closed() {
        let (tx, rx) = oneshot::channel::<ConversationResponse>();
        drop(tx); // Close sender

        let result = rx.await;
        assert!(result.is_err(), "Should error when sender is dropped");
    }
}
