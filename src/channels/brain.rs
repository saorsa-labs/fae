use crate::agent::FaeAgentLlm;
use crate::config::{LlmBackend, SpeechConfig};
use crate::error::{Result, SpeechError};
use crate::llm::LocalLlm;
use crate::pipeline::messages::SentenceChunk;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use tokio::sync::{Mutex, mpsc};

/// Text-response brain used by channel adapters.
///
/// This reuses the same in-repo agent/tool harness as voice interactions.
pub struct ChannelBrain {
    agent: Arc<Mutex<FaeAgentLlm>>,
}

impl ChannelBrain {
    pub async fn from_config(config: &SpeechConfig) -> Result<Self> {
        let mut llm_cfg = config.llm.clone();
        let _ = crate::external_llm::apply_external_profile(&mut llm_cfg)?;

        let requires_local_model = matches!(llm_cfg.backend, LlmBackend::Local)
            || (matches!(llm_cfg.backend, LlmBackend::Agent)
                && !llm_cfg.has_remote_provider_configured())
            || llm_cfg.enable_local_fallback;

        let preloaded_local = if requires_local_model {
            Some(LocalLlm::new(&llm_cfg).await?)
        } else {
            None
        };

        let credential_manager = crate::credentials::create_manager();
        let agent = FaeAgentLlm::new(
            &llm_cfg,
            preloaded_local,
            None,
            None,
            None,
            credential_manager.as_ref(),
        )
        .await?;
        Ok(Self {
            agent: Arc::new(Mutex::new(agent)),
        })
    }

    pub async fn respond(&self, prompt: String) -> Result<String> {
        let (tx, mut rx) = mpsc::channel::<SentenceChunk>(256);
        let collect_task = tokio::spawn(async move {
            let mut out = String::new();
            while let Some(chunk) = rx.recv().await {
                if chunk.is_final {
                    break;
                }
                out.push_str(&chunk.text);
            }
            out
        });

        let interrupted = {
            let mut agent = self.agent.lock().await;
            agent
                .generate_response(prompt, tx, Arc::new(AtomicBool::new(false)))
                .await?
        };

        let mut response = collect_task.await.map_err(|e| {
            SpeechError::Llm(format!("channel response collector task failed: {e}"))
        })?;

        if interrupted && response.trim().is_empty() {
            response = "Request interrupted before completion.".to_owned();
        }
        if response.trim().is_empty() {
            response = "I could not produce a response right now.".to_owned();
        }
        Ok(response.trim().to_owned())
    }
}
