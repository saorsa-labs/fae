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
    ProposalStatus, SkillOpportunityPolicy, SkillProposal, SkillProposalStore,
    detect_skill_opportunities, detect_skill_opportunities_with_policy,
    load_skill_opportunity_policy,
};
pub use store::{IntelligenceStore, RelationshipMeta};
pub use types::{
    ActionResult, ExtractionResult, IntelligenceAction, IntelligenceItem, IntelligenceKind,
};

use crate::memory::SqliteMemoryRepository;
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
    /// Optional override model for extraction (reserved for future local use).
    pub extraction_model: Option<String>,
    /// Memory repository path for creating the intelligence store.
    pub memory_path: std::path::PathBuf,
    /// Runtime event broadcaster.
    pub runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
}

/// Run intelligence extraction in the background.
///
/// This function is designed to be called via `tokio::spawn` after each
/// conversation turn. It builds an extraction prompt, parses the result,
/// and executes any resulting actions.
///
/// Errors are logged but never propagated — extraction is best-effort and
/// must never block or disrupt the conversation pipeline.
///
/// # Note
///
/// Extraction via a local embedded model is planned for Phase 6.2.
/// Until then, extraction is skipped to avoid blocking the pipeline.
pub async fn run_background_extraction(params: ExtractionParams) {
    // Intelligence extraction via local embedded model is deferred to Phase 6.2.
    // Log at trace level so it doesn't clutter normal operation.
    tracing::trace!(
        user_len = params.user_text.len(),
        assistant_len = params.assistant_text.len(),
        extraction_model = ?params.extraction_model,
        "intelligence extraction deferred: local LLM wiring pending (Phase 6.2)"
    );

    if let Some(ref rt) = params.runtime_tx {
        let _ = rt.send(RuntimeEvent::IntelligenceExtraction {
            items_count: 0,
            actions_count: 0,
        });
    }
}

/// Store extracted items and execute resulting actions.
///
/// This is kept as a standalone helper for future use when local extraction
/// is wired up in Phase 6.2.
#[allow(dead_code)]
fn apply_extraction_result(
    result: &crate::intelligence::types::ExtractionResult,
    memory_path: &std::path::Path,
    runtime_tx: &Option<broadcast::Sender<RuntimeEvent>>,
) {
    let items_count = result.items.len();
    let actions_count = result.actions.len();
    info!(
        items_count,
        actions_count, "intelligence extraction completed"
    );

    let repo = match SqliteMemoryRepository::new(memory_path) {
        Ok(r) => r,
        Err(e) => {
            warn!("failed to open SQLite memory for intelligence: {e}");
            return;
        }
    };
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

    if let Some(rt) = runtime_tx {
        let _ = rt.send(RuntimeEvent::IntelligenceExtraction {
            items_count,
            actions_count,
        });
    }
}
