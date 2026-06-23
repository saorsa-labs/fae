# Egress scope, the membrane's real coverage, and the Stage 3 hold

- **Status:** Decision record — corrects a premise of the M2 "all-available default" ruling. **Stage 3 is HELD** pending David's conscious re-decision.
- **Date:** 2026-06-23
- **Trigger:** advisor review following the M2 NOTE-2 merge, verified against source.
- **Supersedes in part:** the "PII membrane" characterization in `conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md` §5.3 and `008a-conductor-recipe-surface-amendment.md` (both patched in the same change).

## 1. The correction (verified in source)

Throughout the conductor track, the egress authority in `crates/fae-pii-membrane/` has been called a **"PII membrane"** — in specs, in the crate name, in the ADR. That name **oversells what the implementation does.** It is a **credential / secret filter**, not a personal-information filter.

`should_block_remote_egress(text)` returns true when `scan(text).level >= SensitivityLevel::LikelyCredential`. The twelve detection rules (all secret-shaped — `crates/fae-pii-membrane/src/lib.rs`):

| Rule | Level | Catches |
|---|---|---|
| `private_key_block` | HighlySensitive | PEM private-key headers |
| `seed_phrase` | HighlySensitive | "seed phrase" / "recovery phrase" / "mnemonic phrase" / "wallet seed" |
| `password_assignment` | HighlySensitive | "my password is …" / "pin: …" |
| `api_key_assignment` | LikelyCredential | "api key: …" / "access token: …" / "bearer token …" |
| `openai_key` | LikelyCredential | `sk-…` tokens |
| `github_token` | LikelyCredential | `gh[pousr]_…` tokens |
| `slack_token` | LikelyCredential | `xox…` tokens |
| `google_key` | LikelyCredential | `AIza…` tokens |
| `ssh_key` | HighlySensitive | `ssh-rsa/ed25519/ecdsa …` |
| `one_time_code` | SensitiveInline | "OTP" / "2FA code" / "verification code" |
| `credential_phrase` | SensitiveInline | "session token" / "backup code" / "recovery code" |
| `long_opaque_token` | LikelyCredential | 40+ char alphanumeric blobs |

**What it does NOT catch (none of these is secret-shaped):** health disclosures ("my biopsy came back"), home/postal address, location, the user's or their family members' names, financial information in prose ("my salary is", "I have $X in savings"), relationship/personal disclosures ("I'm struggling with my marriage"), government IDs (SSN/passport — not in the rule set), phone numbers, email addresses. The Swift origin was honestly named `SensitiveContentPolicy` with levels `likelyCredential`/`highlySensitive`/`sensitiveInline` — **credential/sensitivity language, never "PII."** The "PII" misnomer originated in the Rust crate name `fae-pii-membrane` and was propagated through the specs (by this orchestrator). Owning that: the naming was an error of characterization, and a naming oversell on a safety boundary is itself a risk, because it can lull a decision.

**Proposed follow-up (not this change):** rename the crate to `fae-secret-membrane` (or `fae-credential-filter`) and update call sites, so the name matches the coverage. Until then, read "PII membrane" in older docs as "secret/credential filter."

## 2. What this means for Stage 3 (the load-bearing consequence)

The M2 spec's stated destination default is **`all-available`** (every provisioned cloud worker eligible). The owner ruling two turns ago selected that destination default, with the reasoning (paraphrased from the track) *"we route cloud-backed work through the PII membrane to protect users' data."* **That reasoning rests on the oversold characterization.** The membrane protects **credentials**, not the **personal content** that is the actual substance of a memory-strong companion built to "remember important things from every conversation."

Concretely, **`all-available` as the default means:** for every user, on every install, with no choice made and no disclosure shown, Fae sends deeply personal — non-secret — content (health, finances, relationships, location, family) to OpenAI / Anthropic / Google by default. That is a real inversion of the product's stated identity:

- ADR-003 (local LLM inference): *"Fae's core promise is privacy — all intelligence runs on the user's Mac with no remote servers… Complete privacy — no data leaves the device."* Status: *"remains active and implemented."*
- ADR-001 (cascaded voice pipeline): *"Local-only privacy — all inference on-device, no API keys or remote servers."*
- ADR-007 (companion device handoff): the user *"owns all intelligence."*

A default-on cloud flip doesn't merely *use* cloud — it inverts an identity the product is explicitly built around. There is also **no cloud-egress consent / disclosure UX today** (cloud was not a runtime surface until this track), so "default-on" is structurally "silent egress of personal content," not "informed opt-in."

### Stage 3 status: HELD

Stage 3 (the separate gated commit flipping `FAE_MODEL_MODE` default from `pure-local` to `all-available`) is **on hold** until David makes the default-privacy-posture call **with this corrected premise on the table.** It is not "egress-complete; only release-validation remaining" — that framing assumed the membrane covered personal content, which it does not.

**Recommendation (advisor + this orchestrator):** default to **`pure-local`** (or **`local-symphony`** — cloud-free, keeps coordination power within the user's own devices), and make `all-available` an **explicit, disclosed opt-in** (a first-run cloud-egress disclosure the user affirmatively enables). The mechanism work merged in M2 Stage 1 + NOTE-2 makes **any** of these choices safe to implement — the gates run identically regardless of default; this is purely "what is the right default for a privacy-first companion." The bias should be hard against silently shipping personal conversations to third parties.

If, knowing the membrane stops secrets only, David still wants `all-available` as the default, that is his informed call and the orchestrator will execute it — but it should be made with the corrected premise, and default-on then requires the disclosure UX as real (scoped) work, not a checkbox.

## 3. Scope the "egress-complete" claim so it isn't over-read

The universal egress claim holds for the daemon's **own** outbound calls today (conductor §5 path + the three agent commands). Two boundaries to state explicitly so it isn't mistaken for more:

1. **Post-spawn agent autonomy is outside the membrane by nature.** The conductor gates every prompt Fae *submits* to a Codex/Claude agent; but once spawned, that agent is an autonomous cloud-talking process — its own tool calls and direct network I/O are not (and cannot be) membrane-gated. Fae mediates the agent's filesystem via `PathPolicy`; it cannot mediate the agent's direct cloud chatter. **Acceptable** (provisioning the agent = trusting it), but it belongs in the threat model, not implicit.
2. **Future daemon-side tools are new egress surfaces.** `web_search` / `fetch_url` live in the Swift tool registry today; the daemon "is tool-aware but executes nothing." When **P7 / D3** (`docs/plans/cross-platform-completion-roadmap-2026-06-18.md`) lands a daemon-side ToolHost, those become fresh egress paths that **must route through the same gate pipeline** (mode cap → membrane → provisioning). **Flagged here so it is not rediscovered the way `agent.session_start` was** — i.e., assumed-fine until a review catches it as an ungated surface. The P7 plan should carry a "daemon tool egress must gate through `assert_*_egress_gates`" acceptance item.

## 4. What this does NOT change

- **The merge is correct and stays.** M2 Stage 1 + NOTE-2 are sound egress-gating work. The correction is about the *scope of what the membrane catches* and the *default posture*, not about whether the gating mechanism is safe. It is safe — for credentials, and for preventing unauthorized egress under `pure-local`. The mechanism is exactly what makes any default choice (including the recommended opt-in) safe to ship.
- **The gate pipeline order, the spy-tested invariants, and the fail-closed behavior all stand.** They prevent *secret* leakage and *unauthorized* egress; they do not (and were never going to) prevent personal-content egress under an operator-enabled cloud mode. That is a posture decision, not a mechanism defect.
- **MetaOpt / ADR-008a** is independently reviewable (see this change's ADR-008a v2 patch) and is not blocked by the Stage 3 hold.
