//! Proactive intelligence extraction and delivery.
//!
//! This module enables Fae to learn forward from conversations — extracting
//! dates, relationships, interests, and commitments, then acting on them
//! proactively through scheduled briefings and reminders.
//!
//! # Architecture
//!
//! - **Types** (`types.rs`): `IntelligenceItem`, `IntelligenceKind`, `IntelligenceAction`
//! - **Noise Control** (`noise.rs`): `NoiseController` — budget, cooldown, dedup, quiet hours
//! - **Store** (`store.rs`): `IntelligenceStore` — persistence layer over `MemoryRepository`
//! - **Extraction** (`extraction.rs`): LLM-based extraction from conversation turns
//! - **Extractor** (`extractor.rs`): `IntelligenceExtractor` orchestrator
//! - **Actions** (`actions.rs`): Side-effect executor for scheduler/memory
//!
//! - **Briefing** (`briefing.rs`): Morning briefing builder and delivery
//! - **Research** (`research.rs`): Background research scheduling
//! - **Skill Proposals** (`skill_proposals.rs`): Adaptive skill detection

pub mod actions;
pub mod briefing;
pub mod extraction;
pub mod extractor;
pub mod noise;
pub mod research;
pub mod skill_proposals;
pub mod store;
pub mod types;

pub use actions::execute_actions;
pub use briefing::{
    Briefing, BriefingCategory, BriefingItem, BriefingPriority, build_briefing,
    format_briefing_for_prompt, is_briefing_trigger,
};
pub use extraction::parse_extraction_response;
pub use extractor::IntelligenceExtractor;
pub use noise::{DeliveryBlock, NoiseController};
pub use research::{
    ResearchTask, create_research_tasks, gather_recent_research, has_recent_research,
    store_research_result,
};
pub use skill_proposals::{
    ProposalStatus, SkillProposal, SkillProposalStore, detect_skill_opportunities,
};
pub use store::{IntelligenceStore, RelationshipMeta};
pub use types::{
    ActionResult, ExtractionResult, IntelligenceAction, IntelligenceItem, IntelligenceKind,
};

use crate::config::LlmConfig;
use crate::memory::MemoryRepository;
use crate::runtime::RuntimeEvent;
use tokio::sync::broadcast;
use tracing::{info, warn};

/// Parameters for a background intelligence extraction pass.
pub struct ExtractionParams {
    /// User text from the conversation turn.
    pub user_text: String,
    /// Assistant text from the conversation turn.
    pub assistant_text: String,
    /// Memory context for deduplication and enrichment.
    pub memory_context: Option<String>,
    /// LLM configuration (API URL, model, key).
    pub llm_config: LlmConfig,
    /// Resolved API key (pre-resolved before spawning).
    pub resolved_api_key: String,
    /// Optional override model for extraction.
    pub extraction_model: Option<String>,
    /// Memory repository path for creating the intelligence store.
    pub memory_path: std::path::PathBuf,
    /// Runtime event broadcaster.
    pub runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
}

/// Run intelligence extraction in the background.
///
/// This function is designed to be called via `tokio::spawn` after each
/// conversation turn. It builds an extraction prompt, makes a non-streaming
/// LLM call, parses the result, and executes any resulting actions.
///
/// Errors are logged but never propagated — extraction is best-effort and
/// must never block or disrupt the conversation pipeline.
pub async fn run_background_extraction(params: ExtractionParams) {
    let extractor = IntelligenceExtractor::new();

    let (system_prompt, user_prompt) = extractor.build_extraction_prompt(
        &params.user_text,
        &params.assistant_text,
        params.memory_context.as_deref(),
    );

    let model = params
        .extraction_model
        .unwrap_or_else(|| params.llm_config.api_model.clone());
    let api_url = params.llm_config.api_url.clone();
    let api_key = params.resolved_api_key;
    let max_tokens = extractor.max_tokens();

    // Make the LLM call in a blocking task (ureq is synchronous).
    let raw_response = match tokio::task::spawn_blocking(move || {
        extraction_llm_call(
            &api_url,
            &model,
            &api_key,
            &system_prompt,
            &user_prompt,
            max_tokens,
        )
    })
    .await
    {
        Ok(Ok(response)) => response,
        Ok(Err(e)) => {
            warn!("intelligence extraction LLM call failed: {e}");
            return;
        }
        Err(e) => {
            warn!("intelligence extraction task panicked: {e}");
            return;
        }
    };

    let result = extractor.parse_response(&raw_response);

    if result.is_empty() {
        info!("intelligence extraction found no actionable items");
        if let Some(ref rt) = params.runtime_tx {
            let _ = rt.send(RuntimeEvent::IntelligenceExtraction {
                items_count: 0,
                actions_count: 0,
            });
        }
        return;
    }

    let items_count = result.items.len();
    let actions_count = result.actions.len();
    info!(
        items_count,
        actions_count, "intelligence extraction completed"
    );

    // Store extracted items and execute actions.
    let repo = MemoryRepository::new(&params.memory_path);
    let store = IntelligenceStore::new(repo);

    for item in &result.items {
        if let Err(e) = store.store_item(item, None) {
            warn!("failed to store intelligence item: {e}");
        }
    }

    let action_results = execute_actions(&result.actions, &store);
    for (i, ar) in action_results.iter().enumerate() {
        match ar {
            ActionResult::TaskCreated { task_id } => {
                info!(task_id, "intelligence action created scheduler task");
            }
            ActionResult::MemoryRecordCreated { record_id } => {
                info!(record_id, "intelligence action created memory record");
            }
            ActionResult::RelationshipUpdated { name } => {
                info!(name, "intelligence action updated relationship");
            }
            ActionResult::Failed { reason } => {
                warn!(action_index = i, reason, "intelligence action failed");
            }
        }
    }

    if let Some(ref rt) = params.runtime_tx {
        let _ = rt.send(RuntimeEvent::IntelligenceExtraction {
            items_count,
            actions_count,
        });
    }
}

/// Make a non-streaming LLM API call for intelligence extraction.
///
/// Uses the OpenAI-compatible chat completions endpoint with `stream: false`.
fn extraction_llm_call(
    api_url: &str,
    model: &str,
    api_key: &str,
    system_prompt: &str,
    user_prompt: &str,
    max_tokens: usize,
) -> Result<String, String> {
    let base = api_url
        .strip_suffix("/v1")
        .unwrap_or(api_url)
        .trim_end_matches('/');
    let url = format!("{base}/v1/chat/completions");

    let body = serde_json::json!({
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "stream": false,
        "temperature": 0.3,
        "max_tokens": max_tokens,
    });

    let body_str = serde_json::to_string(&body).map_err(|e| format!("JSON serialize: {e}"))?;

    let agent = ureq::agent();
    let mut req = agent.post(&url).set("Content-Type", "application/json");
    if !api_key.is_empty() {
        req = req.set("Authorization", &format!("Bearer {api_key}"));
    }

    let response = req
        .send_string(&body_str)
        .map_err(|e| format!("extraction API request failed: {e}"))?;

    let response_body: serde_json::Value = response
        .into_json()
        .map_err(|e| format!("extraction API response parse failed: {e}"))?;

    // Extract the assistant's message content from the response.
    response_body["choices"][0]["message"]["content"]
        .as_str()
        .map(|s| s.to_owned())
        .ok_or_else(|| "no content in extraction response".to_owned())
}
