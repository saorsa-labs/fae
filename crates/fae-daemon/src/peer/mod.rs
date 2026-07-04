//! Phase E — x0x peer messaging: the trust core (commit 1).
//!
//! Pure, transport-free building blocks for Fae↔Fae peer ingress over x0xd:
//!
//! - [`config`] — env + x0x-data-dir discovery (`FAE_X0X_*`); returns `None`
//!   (ingress off) on ANY missing/invalid required piece, never an error.
//! - [`verifier`] — [`fae_envelope_gate::SignatureVerifier`] impl enforcing
//!   algorithm + signature shape + sender-tier-by-kind ([`verifier::TierPolicy`]).
//! - [`handoff`] — the `session_handoff` payload schema (`deny_unknown_fields`),
//!   decode from an accepted envelope, and a 64 KiB-capped envelope builder.
//! - [`handler`] — pure per-kind dispatch to a [`handler::PeerEventSink`].
//!
//! Deliberately NO network code and NO ingress task here: the x0xd SSE client,
//! the EventBus wiring, and auto-reply land in commit 2 (after Phase D folds).
//! This file is module declarations only.

pub mod config;
pub mod handler;
pub mod handoff;
pub mod verifier;
