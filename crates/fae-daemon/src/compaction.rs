//! Pure context-compaction planning (Phase G1).
//!
//! The daemon is stateless per turn — Swift resends the full message list every
//! conversation turn, so the ONLY daemon-owned conversation history that can
//! outgrow a model's context window is [`crate::delegate`]'s child loop. This
//! module is the shared, side-effect-free arithmetic both surfaces reason about:
//!
//! * [`estimate_tokens`] — the workspace's single token-count heuristic
//!   (~4 chars/token). Promoted from `delegate.rs`'s old `approx_output_tokens`
//!   so budget accounting and compaction planning agree by construction.
//! * [`PromptBudget`] — a model context window with the 80% compaction ceiling.
//! * [`plan_compaction`] — decides, given a message list, a budget, and a
//!   hysteresis [`Watermark`], whether to fold the oldest turns into a summary
//!   and which message indices to evict.
//!
//! Nothing here does I/O or touches the engine; the caller performs the actual
//! summarizer generation and history mutation. Keeping the decision pure makes
//! the eviction geometry and hysteresis exhaustively unit-testable.

use fae_engine::ChatMessage;

/// How many of the most-recent messages are ALWAYS retained verbatim (never
/// folded into a summary), so the model keeps immediate conversational context.
pub const RETAINED_TAIL_MESSAGES: usize = 4;

/// Hysteresis floor: the caller-tracked turn counter must reach this before a
/// count-triggered recompute fires. Stops us re-summarizing on every single
/// turn once the prompt first crosses the budget ceiling — a recompute then
/// only recurs after this many further turns (or a hard tail-over-budget trip).
pub const RECOMPUTE_EVICTION_THRESHOLD: usize = 8;

/// Estimate the token count of a text span: ~4 chars/token, ceiling division.
///
/// A documented heuristic — the engine surfaces no real token count — so this
/// gates budgets and compaction thresholds only, never a hard correctness
/// boundary. Monotonic in length: a longer string never estimates fewer tokens.
#[must_use]
pub fn estimate_tokens(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

/// Estimate the tokens a chat message contributes to a prompt. Text-only: the
/// delegate child loop (the sole compaction caller) carries no audio clips, so
/// only `content` is counted.
#[must_use]
fn estimate_message(message: &ChatMessage) -> usize {
    estimate_tokens(&message.content)
}

/// Estimate the tokens a whole message slice contributes.
#[must_use]
pub fn estimate_messages(messages: &[ChatMessage]) -> usize {
    messages.iter().map(estimate_message).sum()
}

/// A token budget derived from a model's context window. Compaction targets 80%
/// of the window, leaving 20% headroom for the reply plus chat-template overhead.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PromptBudget {
    /// The full model context window, in (estimated) tokens.
    window: usize,
}

impl PromptBudget {
    /// Build a budget from a model context window.
    #[must_use]
    pub fn new(window: usize) -> PromptBudget {
        PromptBudget { window }
    }

    /// The compaction ceiling: 80% of the window. Integer arithmetic
    /// (`× 4 / 5`, saturating) so there is no float rounding drift.
    #[must_use]
    pub fn ceiling(&self) -> usize {
        self.window.saturating_mul(4) / 5
    }
}

/// Caller-maintained hysteresis state carried between compaction checks so a
/// summary is not recomputed on every turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Watermark {
    /// Turns accumulated since the last recompute (the spec's
    /// "evicted-since-last-summary" counter). The caller increments it as the
    /// conversation grows and resets it to 0 immediately after a recompute.
    pub turns_since_summary: usize,
}

/// The decision produced by [`plan_compaction`]: whether to recompute the pinned
/// summary this cycle, and which message indices to evict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactionPlan {
    /// Whether the caller should recompute the pinned summary this cycle.
    pub recompute: bool,
    /// Message indices to fold into the summary, oldest-first ascending. Always
    /// a prefix `0..k` of the message list; empty when `!recompute`.
    pub evict: Vec<usize>,
    /// Estimated tokens of the messages retained after eviction — the tail when
    /// recomputing, the whole list otherwise. Lets the caller assert headroom.
    pub retained_tokens: usize,
    /// The budget ceiling (80% of the window) used for the decision — surfaced
    /// for telemetry and tests.
    pub ceiling: usize,
}

/// Plan a compaction over `messages`.
///
/// Evicts oldest-first everything before the retained tail
/// ([`RETAINED_TAIL_MESSAGES`] most-recent messages). A recompute fires only
/// when there is something evictable AND either:
///
/// * the retained tail ALONE already meets/exceeds the budget ceiling (a hard
///   trip that fires regardless of the watermark), or
/// * the whole prompt exceeds the ceiling AND the watermark has reached
///   [`RECOMPUTE_EVICTION_THRESHOLD`] (the hysteresis gate).
///
/// Otherwise the plan is a no-op (`recompute: false`, empty `evict`).
#[must_use]
pub fn plan_compaction(
    messages: &[ChatMessage],
    budget: PromptBudget,
    watermark: Watermark,
) -> CompactionPlan {
    let ceiling = budget.ceiling();
    let total_tokens = estimate_messages(messages);

    // The retained tail is the last RETAINED_TAIL_MESSAGES; everything before it
    // (indices 0..tail_start) is evictable, oldest-first.
    let tail_start = messages.len().saturating_sub(RETAINED_TAIL_MESSAGES);
    let tail_tokens = estimate_messages(&messages[tail_start..]);

    let has_evictable = tail_start > 0;
    let over_budget = total_tokens > ceiling;
    let count_trigger = watermark.turns_since_summary >= RECOMPUTE_EVICTION_THRESHOLD;
    let tail_trigger = tail_tokens >= ceiling && ceiling > 0;

    let recompute = has_evictable && (tail_trigger || (over_budget && count_trigger));

    if !recompute {
        return CompactionPlan {
            recompute: false,
            evict: Vec::new(),
            retained_tokens: total_tokens,
            ceiling,
        };
    }
    CompactionPlan {
        recompute: true,
        evict: (0..tail_start).collect(),
        retained_tokens: tail_tokens,
        ceiling,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_engine::Role;

    /// A user message whose content is `chars` bytes long (⇒ `chars / 4` est. tokens).
    fn msg(chars: usize) -> ChatMessage {
        ChatMessage::text(Role::User, "x".repeat(chars))
    }

    #[test]
    fn estimate_is_char_quarter_ceiling() {
        assert_eq!(estimate_tokens(""), 0);
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("abcde"), 2);
        assert_eq!(estimate_tokens("abcdefgh"), 2);
    }

    #[test]
    fn estimate_is_monotonic_in_length() {
        let mut previous = 0;
        for len in 0..64 {
            let current = estimate_tokens(&"a".repeat(len));
            assert!(
                current >= previous,
                "estimate must never shrink as text grows (len {len})"
            );
            previous = current;
        }
    }

    #[test]
    fn ceiling_is_eighty_percent_of_window() {
        assert_eq!(PromptBudget::new(1000).ceiling(), 800);
        assert_eq!(PromptBudget::new(10).ceiling(), 8);
        assert_eq!(PromptBudget::new(0).ceiling(), 0);
        // Documented rounding: integer × 4 / 5 truncates (no float drift).
        assert_eq!(PromptBudget::new(9).ceiling(), 7);
    }

    #[test]
    fn empty_history_is_a_noop() {
        let plan = plan_compaction(&[], PromptBudget::new(100), Watermark::default());
        assert!(!plan.recompute);
        assert!(plan.evict.is_empty());
        assert_eq!(plan.retained_tokens, 0);
    }

    #[test]
    fn single_oversized_message_cannot_be_compacted() {
        // One message far bigger than the ceiling — but it is within the retained
        // tail (len 1 ≤ RETAINED_TAIL), so there is nothing to evict. The caller
        // must hard-truncate instead; compaction refuses to drop the only turn.
        let history = vec![msg(1000)]; // 250 est. tokens
        let plan = plan_compaction(&history, PromptBudget::new(100), Watermark::default());
        assert!(!plan.recompute);
        assert!(plan.evict.is_empty());
        assert_eq!(plan.retained_tokens, 250);
    }

    #[test]
    fn eviction_is_oldest_first_prefix() {
        // 10 messages of 40 tokens each; tail is the last 4 ⇒ evict indices 0..6.
        let history: Vec<ChatMessage> = (0..10).map(|_| msg(160)).collect();
        // window 100 ⇒ ceiling 80; tail (4×40=160) alone exceeds it ⇒ recompute.
        let plan = plan_compaction(&history, PromptBudget::new(100), Watermark::default());
        assert!(plan.recompute);
        assert_eq!(plan.evict, vec![0, 1, 2, 3, 4, 5]);
        // Ascending, contiguous prefix.
        assert!(plan.evict.windows(2).all(|w| w[0] + 1 == w[1]));
        assert_eq!(*plan.evict.first().expect("non-empty"), 0);
        // Retained tokens are the tail only.
        assert_eq!(plan.retained_tokens, 4 * 40);
    }

    #[test]
    fn watermark_hysteresis_suppresses_recompute_below_threshold() {
        // 10 messages of 40 tokens: total 400, tail (4) 160. window 250 ⇒
        // ceiling 200: over budget (400>200) but tail (160) within ceiling, so
        // only the WATERMARK gates the recompute.
        let history: Vec<ChatMessage> = (0..10).map(|_| msg(160)).collect();
        let budget = PromptBudget::new(250);

        // Below threshold ⇒ no recompute even though we are over budget.
        let below = Watermark {
            turns_since_summary: RECOMPUTE_EVICTION_THRESHOLD - 1,
        };
        let plan = plan_compaction(&history, budget, below);
        assert!(
            !plan.recompute,
            "must not recompute below the hysteresis threshold"
        );
        assert!(plan.evict.is_empty());

        // At threshold ⇒ recompute fires.
        let at = Watermark {
            turns_since_summary: RECOMPUTE_EVICTION_THRESHOLD,
        };
        let plan = plan_compaction(&history, budget, at);
        assert!(plan.recompute, "must recompute at/above the threshold");
        assert_eq!(plan.evict, vec![0, 1, 2, 3, 4, 5]);
    }

    #[test]
    fn tail_over_budget_forces_recompute_regardless_of_watermark() {
        // Tail alone exceeds the ceiling ⇒ hard trip even with a zero watermark.
        let history: Vec<ChatMessage> = (0..10).map(|_| msg(160)).collect();
        let plan = plan_compaction(&history, PromptBudget::new(100), Watermark::default());
        assert!(plan.recompute);
    }

    #[test]
    fn within_budget_never_compacts() {
        // Plenty of headroom ⇒ no recompute regardless of a high watermark.
        let history: Vec<ChatMessage> = (0..10).map(|_| msg(4)).collect(); // 1 tok each
        let hot = Watermark {
            turns_since_summary: RECOMPUTE_EVICTION_THRESHOLD * 4,
        };
        let plan = plan_compaction(&history, PromptBudget::new(100_000), hot);
        assert!(!plan.recompute);
        assert!(plan.evict.is_empty());
    }
}
