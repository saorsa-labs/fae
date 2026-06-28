//! ADR-013 Vision A — the daemon tool/skill execution host (fluers substrate).
//!
//! **A1 (this commit): wiring + reachability proof only.** `fae-daemon` now
//! depends on `fluers-core` + `fluers-runtime` as a **git-dep pinned to v0.3.0**
//! (NOT a path-dep — so CI needs no sibling `../fluers` checkout; S19 coupling
//! finding). v0.3.0 ships the generic `ToolPolicy` hook (A0) + the `edit` tool
//! and non-truncating `read_file_full` (A2-pre).
//! The [`WITNESS`] const type-checks the A2 foundation types, so a missing or
//! renamed export in fluers fails `cargo check` HERE, not silently in A2.
//!
//! **A2 (next slice): the governed ToolHost itself.** fluers native tools
//! (`read/write/edit/bash/grep/glob` — note `edit` is added to fluers as part of
//! ADR-013 §changes) + Skills over a `SessionEnv`/`Sandbox`, behind a Fae
//! [`ToolPolicy`][fluers_core::ToolPolicy] impl that composes:
//! - the control-plane scope check (existing `tool:execute:safe/dangerous`),
//! - `DamageControlPolicy`,
//! - `PathPolicy`,
//! - **the egress membrane for any networked tool** (`web_search`/`fetch_url` →
//!   `assert_*_egress_gates`; roadmap egress flag 2026-06-23 — wired from day
//!   one, not rediscovered later),
//! with every execution producing a control-plane **fail-closed audit** row.
//!
//! **NOT here (Vision B, post-P9, separately gated):** loop relocation,
//! conductor-as-`ModelProvider`, or `RemoteSwiftTool`. In Vision A the Swift
//! multi-turn loop still drives; it calls INTO this host for portable/native
//! tool execution (A3 surfaces the `tool.execute` entry point).
//!
//! This module deliberately lives as a sibling of `conductor/` (tool/skill
//! *execution* is a separate daemon subsystem from *routing*) and is outside the
//! mesh boundary guard's scope (that guard protects the conductor core from
//! x0x-family external-mesh deps; fluers is the sanctioned substrate, not mesh).

use fluers_core::tool::InvokeContext;
use fluers_core::{PolicyVerdict, ToolPolicy};
use fluers_runtime::{LocalSessionEnv, SessionEnv, Skill};

/// Compile-time witness that the A2 foundation types resolve from the fluers
/// 0.2.0 git-dep. Emits no symbol and no runtime code; the anonymous `const _`
/// never triggers dead-code warnings. It exists only to make `cargo check` fail
/// if fluers stops exporting (or renames) a type A2 will build the governed
/// ToolHost on.
const _: () = {
    fn _witness(
        _policy: &dyn ToolPolicy,
        _verdict: PolicyVerdict,
        _ctx: &InvokeContext,
        // `SessionEnv` is a trait; `LocalSessionEnv` is the concrete impl A2
        // builds the sandboxed tool/skill host on. Both must resolve.
        _env: &dyn SessionEnv,
        _local: &LocalSessionEnv,
        _skill: &Skill,
    ) {
    }
};
