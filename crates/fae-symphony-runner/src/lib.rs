//! `fae-symphony-runner` — an x0x-symphony [`Runner`](x0x_symphony_core::Runner)
//! implemented over the fae-daemon control socket.
//!
//! A single binary that lets a Fae instance participate in a group-of-Fae task
//! swarm: it claims a `TaskItem` from x0xd (trust-gated, ML-DSA-signed by x0xd),
//! executes the work by driving `fae-daemon`'s native jailed agentic loop
//! (`conversation.delegate`, Phase F1) inside an isolated workspace, and lets
//! the x0x-symphony orchestrator publish a **signed** handoff + proof artefacts.
//!
//! Architecture (all injected into the stock `x0x-symphony-orchestrator`):
//! * [`FaeRunner`] implements `Runner` by delegating to the daemon socket.
//! * `X0xCrdtTracker` (from `x0x-symphony-tracker-x0x-crdt`) is the production
//!   tracker; `X0xdClient` (from `x0x-symphony-signing`) signs handoffs.
//! * The orchestrator itself is consumed unmodified via its public
//!   `Orchestrator::new(tracker, runner, workspace, clock, config)` constructor —
//!   no symphony bin/config is required.
//!
//! Quarantine invariant: only this crate depends on any `x0x-symphony-*` crate.
//! `fae-daemon` never does — the runner is a pure client of the daemon's
//! existing wire protocol via [`fae_control_plane`].

#![forbid(unsafe_code)]

pub mod daemon_client;
pub mod runner;

pub use daemon_client::{DaemonClient, DaemonError, DelegationBudget, DelegationResponse};
pub use runner::{FaeRunner, DEFAULT_TOOLSET};
