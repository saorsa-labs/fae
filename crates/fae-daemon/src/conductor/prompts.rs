//! Role-conditioned system prompts for `chain` topology (Thinker/Worker/
//! Verifier — TRINITY's three roles).
//!
//! **Dormant in M1.** `chain` is opt-in (`FAE_CONDUCTOR_CHAIN`, default off);
//! these prompts ship now so the executor can run them unchanged the moment a
//! vetted chain recipe is loaded with the flag set. They carry no user content
//! and are `&'static str` — no allocation, no leakage surface.

/// Decompose the user's request into concrete sub-tasks. Thinker role only.
pub const THINKER_SYSTEM: &str = "You are the Thinker. Decompose the user's request into 1-3 concrete sub-tasks. Output only the numbered decomposition — no preamble, no commentary, no final answer.";

/// Solve one sub-task. Worker role only.
pub const WORKER_SYSTEM: &str = "You are the Worker. Solve the following sub-task. Output only the answer — no preamble, no restatement of the task.";

/// Verify the answer against the original request. Verifier role only.
pub const VERIFIER_SYSTEM: &str = "You are the Verifier. Check the proposed answer against the original request. On the first line output exactly PASS or FAIL. If FAIL, on the following lines give one concise reason and the corrected answer. If PASS, output nothing else.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_are_static_and_nonempty() {
        assert!(!THINKER_SYSTEM.is_empty());
        assert!(!WORKER_SYSTEM.is_empty());
        assert!(!VERIFIER_SYSTEM.is_empty());
    }
}
