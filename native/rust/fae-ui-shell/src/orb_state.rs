//! Orb-host-owns-state — the pure grace-hold state machine.
//!
//! Derives the orb's visible mode (`Thinking` / `Speaking` / `Quiescent`) from a
//! stream of daemon events, **without flicker**: a down-transition to idle waits
//! a grace period (~1.4 s) and is cancelled by any resuming event. This fixes
//! the measured `thinking → idle → thinking` / `speaking → idle → speaking`
//! flips caused by the pipeline toggling `assistant.generating` mid-turn and by
//! sentence-streamed TTS (one `playback_ended` per sentence).
//!
//! Pure + deterministic: time enters only as a monotonic `now_ms` argument to
//! [`OrbStateMachine::tick`], so the whole machine is unit-testable with fake
//! clocks and exact flicker sequences. The bridge thread feeds [`OrbInput`]; the
//! render loop applies the resulting [`OrbMode`].

use std::time::Duration;

/// The down-transition grace window. A resuming event within this window
/// cancels the pending idle (so thinking holds across the `generating` toggle
/// and speaking holds across sentence gaps). Tuned from the live 2026-06-17
/// trace (sentence gaps ~0.4–0.8 s; the generating toggle gap is shorter).
pub const GRACE: Duration = Duration::from_millis(1400);

/// The orb's visible mode. Ordered so the render path can compare precedence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrbMode {
    /// Bright idle — no generation or playback active and grace elapsed.
    Quiescent,
    /// Generating a reply (steady through the mid-turn toggle).
    Thinking,
    /// Playing back TTS (steady across sentence gaps).
    Speaking,
}

/// Inputs the bridge forwards from the daemon event stream.
#[derive(Debug, Clone, PartialEq)]
pub enum OrbInput {
    /// `assistant.generating {active}`.
    Generating(bool),
    /// `audio.level {rms}` — also carries the level to ride the voice.
    AudioLevel(f32),
    /// `audio.playback_ended` — one sentence finished.
    PlaybackEnded,
    /// The daemon connection dropped/reconnected: clear any held state and go
    /// idle immediately (no point grace-holding a signal whose source is gone).
    ConnectionReset,
}

/// The daemon events the bridge forwards to the render loop (pre-state-machine).
/// The render loop feeds the audio level into `bridge_audio` AND runs the
/// [`OrbStateMachine`] to derive the mode. Carried via `UserEvent::DaemonOrb`.
#[derive(Debug, Clone, PartialEq)]
pub enum OrbDaemonEvent {
    /// `assistant.generating {active}`.
    Generating(bool),
    /// `audio.level {rms}` (clamped 0..1).
    AudioLevel(f32),
    /// `audio.playback_ended`.
    PlaybackEnded,
    /// `info.update {items}` — the green-dot indicator set.
    InfoUpdate(InfoItems),
    /// Daemon connection reset: drop to idle, clear the voice ride.
    ConnectionReset,
}

/// The info indicator set (forwarded whole so the pill can render N items).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct InfoItems {
    pub items: Vec<InfoItem>,
}

/// One info indicator item. `kind` routes the click (research/x0x/app/url).
#[derive(Debug, Clone, PartialEq)]
pub struct InfoItem {
    pub id: String,
    pub kind: String,
    pub title: String,
}

impl OrbDaemonEvent {
    /// Convert a wire event into the pure state-machine input (audio + info are
    /// side-band — only generating/ended/reset move the mode).
    #[must_use]
    pub fn to_state_input(&self) -> Option<OrbInput> {
        match self {
            Self::Generating(active) => Some(OrbInput::Generating(*active)),
            Self::AudioLevel(_) => Some(OrbInput::AudioLevel(0.0)),
            Self::PlaybackEnded => Some(OrbInput::PlaybackEnded),
            Self::ConnectionReset => Some(OrbInput::ConnectionReset),
            Self::InfoUpdate(_) => None,
        }
    }
}

/// A pending down-transition: the time at which it should fire, and the mode
/// we'd return to (always `Quiescent` today, but kept explicit for future
/// intermediate modes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PendingIdle {
    fire_at_ms: u128,
}

/// The state machine. Holds the *effective* mode and any armed grace timer.
#[derive(Debug, Clone, PartialEq)]
pub struct OrbStateMachine {
    mode: OrbMode,
    pending: Option<PendingIdle>,
}

impl Default for OrbStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl OrbStateMachine {
    /// Create a machine starting in the bright-idle [`OrbMode::Quiescent`].
    #[must_use]
    pub fn new() -> Self {
        Self {
            mode: OrbMode::Quiescent,
            pending: None,
        }
    }

    /// The current effective mode (after applying any grace expiry).
    #[must_use]
    #[allow(dead_code)] // public API; the render loop drives via event()/tick()
    pub fn mode(&self) -> OrbMode {
        self.mode
    }

    /// Apply one daemon input at wall-clock time `now_ms`. Returns the new
    /// effective mode (the bridge forwards this to the render path; equal to the
    /// previous mode when nothing visible changed).
    pub fn event(&mut self, input: OrbInput, now_ms: u128) -> OrbMode {
        match input {
            OrbInput::Generating(true) => {
                // (Re)entering generation cancels any pending idle and shows
                // thinking — UNLESS we're already speaking (TTS started), in
                // which case speaking outranks thinking.
                self.pending = None;
                if self.mode != OrbMode::Speaking {
                    self.mode = OrbMode::Thinking;
                }
            }
            OrbInput::Generating(false) => {
                // Generation finished — arm a grace idle (a `generating(true)`
                // or `audio.level` may follow within the gap).
                self.arm_idle(now_ms);
            }
            OrbInput::AudioLevel(_rms) => {
                // Any playback level cancels pending idle and shows speaking.
                self.pending = None;
                self.mode = OrbMode::Speaking;
            }
            OrbInput::PlaybackEnded => {
                // One sentence ended — arm a grace idle (the next sentence's
                // level arrives within the gap). We stay Speaking until grace
                // expires so the orb holds across the gap.
                self.arm_idle(now_ms);
            }
            OrbInput::ConnectionReset => {
                self.pending = None;
                self.mode = OrbMode::Quiescent;
            }
        }
        self.mode
    }

    /// Advance the clock. If a grace timer expired, transition to idle. Returns
    /// the effective mode. Call this from the render loop's tick.
    pub fn tick(&mut self, now_ms: u128) -> OrbMode {
        if let Some(p) = self.pending {
            if now_ms >= p.fire_at_ms {
                self.pending = None;
                self.mode = OrbMode::Quiescent;
            }
        }
        self.mode
    }

    /// Arm a down-transition `GRACE` into the future. No-op if already pending
    /// (the earliest expiry wins — conservative; in practice events are dense
    /// enough that re-arming wouldn't matter).
    fn arm_idle(&mut self, now_ms: u128) {
        if self.pending.is_none() {
            self.pending = Some(PendingIdle {
                fire_at_ms: now_ms + GRACE.as_millis(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thinking_holds_across_generating_toggle_within_grace() {
        // The measured flicker: generating(true) → generating(false) →
        // generating(true) must NOT emit idle in the gap.
        let mut m = OrbStateMachine::new();
        assert_eq!(m.event(OrbInput::Generating(true), 0), OrbMode::Thinking);
        assert_eq!(m.event(OrbInput::Generating(false), 200), OrbMode::Thinking);
        // Grace arming doesn't immediately idle; the resume cancels it.
        assert_eq!(m.event(OrbInput::Generating(true), 400), OrbMode::Thinking);
        // Tick well past the (now-cancelled) grace — still thinking.
        assert_eq!(m.tick(5_000), OrbMode::Thinking);
    }

    #[test]
    fn speaking_holds_across_sentence_gaps_within_grace() {
        // Sentence-streamed TTS: level → ended → level → ended must NOT emit
        // idle between sentences.
        let mut m = OrbStateMachine::new();
        assert_eq!(m.event(OrbInput::AudioLevel(0.4), 0), OrbMode::Speaking);
        assert_eq!(m.event(OrbInput::PlaybackEnded, 800), OrbMode::Speaking);
        // Next sentence within grace — no idle flicker.
        assert_eq!(m.event(OrbInput::AudioLevel(0.5), 1_000), OrbMode::Speaking);
        assert_eq!(m.tick(1_200), OrbMode::Speaking);
    }

    #[test]
    fn grace_expiry_eventually_returns_to_idle() {
        let mut m = OrbStateMachine::new();
        m.event(OrbInput::Generating(true), 0);
        m.event(OrbInput::Generating(false), 100);
        // Before grace — still thinking.
        assert_eq!(m.tick(1_000), OrbMode::Thinking);
        // At grace expiry — idle.
        assert_eq!(m.tick(1_501), OrbMode::Quiescent);
    }

    #[test]
    fn speaking_outranks_thinking_when_generation_still_active() {
        // TTS starts while generating flag is still true (pipeline overlap).
        let mut m = OrbStateMachine::new();
        m.event(OrbInput::Generating(true), 0);
        assert_eq!(m.event(OrbInput::AudioLevel(0.3), 500), OrbMode::Speaking);
        // generating(false) arriving while speaking arms idle but stays speaking.
        assert_eq!(m.event(OrbInput::Generating(false), 600), OrbMode::Speaking);
        assert_eq!(m.tick(700), OrbMode::Speaking);
    }

    #[test]
    fn connection_reset_drops_to_idle_immediately() {
        let mut m = OrbStateMachine::new();
        m.event(OrbInput::AudioLevel(0.5), 0);
        assert_eq!(m.event(OrbInput::ConnectionReset, 10), OrbMode::Quiescent);
    }

    #[test]
    #[allow(clippy::vec_init_then_push)] // sequential pushes mirror the trace
    fn full_turn_sequence_no_flicker() {
        // A representative turn: think → (generating toggles) → speak (3
        // sentences) → idle. Assert the mode sequence has no idle-between-active.
        let mut m = OrbStateMachine::new();
        let mut seq = Vec::new();
        seq.push(m.event(OrbInput::Generating(true), 0)); // think
        seq.push(m.event(OrbInput::Generating(false), 300)); // gap
        seq.push(m.event(OrbInput::Generating(true), 350)); // resume
        seq.push(m.event(OrbInput::AudioLevel(0.4), 900)); // speak s1
        seq.push(m.event(OrbInput::PlaybackEnded, 1_600)); // s1 end
        seq.push(m.event(OrbInput::AudioLevel(0.5), 1_900)); // speak s2
        seq.push(m.event(OrbInput::PlaybackEnded, 2_600)); // s2 end
        seq.push(m.event(OrbInput::AudioLevel(0.3), 2_900)); // speak s3
        seq.push(m.event(OrbInput::PlaybackEnded, 3_600)); // s3 end
        seq.push(m.tick(3_700)); // within grace
        seq.push(m.tick(5_101)); // past grace → idle
                                 // No Quiescent should appear before the final tick.
        let first_idle = seq.iter().position(|&x| x == OrbMode::Quiescent);
        assert_eq!(first_idle, Some(seq.len() - 1), "idle only at the very end");
    }
}
