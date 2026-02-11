//! Model selection logic for startup model picker.
//!
//! This module provides types and functions for deciding whether to auto-select
//! the best available model or prompt the user when multiple top-tier models exist.

use crate::model_tier::{ModelTier, tier_for_provider_model};

/// Reference to a provider/model pair with tier and priority metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderModelRef {
    pub provider: String,
    pub model: String,
    /// Capability tier (auto-computed from model ID).
    pub tier: ModelTier,
    /// User-defined priority within the same tier (higher = preferred).
    pub priority: i32,
}

impl ProviderModelRef {
    /// Build a reference, auto-computing the tier from model + provider IDs.
    pub fn new(provider: String, model: String, priority: i32) -> Self {
        let tier = tier_for_provider_model(&provider, &model);
        Self {
            provider,
            model,
            tier,
            priority,
        }
    }

    /// Format as "provider/model" for display.
    pub fn display(&self) -> String {
        format!("{}/{}", self.provider, self.model)
    }
}

/// Decision about model selection at startup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelSelectionDecision {
    /// Auto-select the single best model.
    AutoSelect(ProviderModelRef),
    /// Prompt user to choose from multiple top-tier models.
    PromptUser(Vec<ProviderModelRef>),
    /// No models available.
    NoModels,
}

/// Decide whether to auto-select a model or prompt the user.
///
/// # Decision Logic
///
/// - If no candidates exist → `NoModels`
/// - If exactly one candidate → `AutoSelect(that_candidate)`
/// - If multiple candidates share the top tier → `PromptUser(all_top_tier_candidates)`
/// - Otherwise → `AutoSelect(first_candidate)` (best tier/priority already sorted)
///
/// # Examples
///
/// ```
/// use fae::model_selection::{decide_model_selection, ModelSelectionDecision, ProviderModelRef};
///
/// // No models
/// assert_eq!(decide_model_selection(&[]), ModelSelectionDecision::NoModels);
///
/// // Single model
/// let single = vec![ProviderModelRef::new("provider".into(), "model".into(), 0)];
/// match decide_model_selection(&single) {
///     ModelSelectionDecision::AutoSelect(_) => {},
///     _ => panic!("Expected AutoSelect"),
/// }
/// ```
pub fn decide_model_selection(candidates: &[ProviderModelRef]) -> ModelSelectionDecision {
    if candidates.is_empty() {
        return ModelSelectionDecision::NoModels;
    }

    if candidates.len() == 1 {
        return ModelSelectionDecision::AutoSelect(candidates[0].clone());
    }

    // Check if multiple candidates share the top tier
    let top_tier = &candidates[0].tier;
    let top_tier_candidates: Vec<ProviderModelRef> = candidates
        .iter()
        .take_while(|c| &c.tier == top_tier)
        .cloned()
        .collect();

    if top_tier_candidates.len() > 1 {
        ModelSelectionDecision::PromptUser(top_tier_candidates)
    } else {
        // Only one top-tier model, auto-select it
        ModelSelectionDecision::AutoSelect(candidates[0].clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model_tier::ModelTier;

    fn make_ref(provider: &str, model: &str, tier: ModelTier, priority: i32) -> ProviderModelRef {
        ProviderModelRef {
            provider: provider.to_owned(),
            model: model.to_owned(),
            tier,
            priority,
        }
    }

    #[test]
    fn test_no_models() {
        let decision = decide_model_selection(&[]);
        assert_eq!(decision, ModelSelectionDecision::NoModels);
    }

    #[test]
    fn test_single_model() {
        let candidates = vec![make_ref("anthropic", "claude-opus", ModelTier::Flagship, 0)];
        match decide_model_selection(&candidates) {
            ModelSelectionDecision::AutoSelect(model) => {
                assert_eq!(model.provider, "anthropic");
                assert_eq!(model.model, "claude-opus");
            }
            _ => panic!("Expected AutoSelect for single model"),
        }
    }

    #[test]
    fn test_multiple_same_tier_prompts_user() {
        let candidates = vec![
            make_ref("anthropic", "claude-opus", ModelTier::Flagship, 10),
            make_ref("openai", "gpt-4o", ModelTier::Flagship, 5),
            make_ref("google", "gemini-pro", ModelTier::Strong, 0),
        ];
        match decide_model_selection(&candidates) {
            ModelSelectionDecision::PromptUser(models) => {
                assert_eq!(models.len(), 2);
                assert_eq!(models[0].tier, ModelTier::Flagship);
                assert_eq!(models[1].tier, ModelTier::Flagship);
            }
            _ => panic!("Expected PromptUser for multiple same-tier models"),
        }
    }

    #[test]
    fn test_multiple_different_tiers_auto_selects_best() {
        let candidates = vec![
            make_ref("anthropic", "claude-opus", ModelTier::Flagship, 0),
            make_ref("anthropic", "claude-haiku", ModelTier::Mid, 0),
            make_ref("local", "qwen", ModelTier::Small, 0),
        ];
        match decide_model_selection(&candidates) {
            ModelSelectionDecision::AutoSelect(model) => {
                assert_eq!(model.provider, "anthropic");
                assert_eq!(model.model, "claude-opus");
                assert_eq!(model.tier, ModelTier::Flagship);
            }
            _ => panic!("Expected AutoSelect when different tiers"),
        }
    }

    #[test]
    fn test_provider_model_ref_display() {
        let model = make_ref("anthropic", "claude-opus", ModelTier::Flagship, 0);
        assert_eq!(model.display(), "anthropic/claude-opus");
    }

    #[test]
    fn test_provider_model_ref_new() {
        // The `new` constructor auto-computes tier
        let model = ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10);
        assert_eq!(model.tier, ModelTier::Flagship);
        assert_eq!(model.priority, 10);
    }
}
