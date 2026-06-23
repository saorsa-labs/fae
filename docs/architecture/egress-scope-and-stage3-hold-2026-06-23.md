# Security model: Fae-as-local-coordinator, the membrane's real coverage, and the Stage 3 default decision

- **Status:** Decision record — **DECIDED 2026-06-23 (owner acknowledgment).** Two things: (1) the **security architecture** — Fae (local Gemma) is the coordinator and the primary trust boundary; she coordinates other agents as tools; the membrane is defense-in-depth; (2) the **Stage 3 default** — `pure-local` remains the default; `all-available` is an explicit, disclosed opt-in. The Stage 3 flip-to-`all-available`-default is **not proceeding**; cloud egress stays opt-in. (Originally flagged HELD pending decision; resolved by owner acknowledgment same day.)
- **Date:** 2026-06-23
- **Trigger:** advisor review following the M2 NOTE-2 merge, verified against source.
- **Supersedes in part:** the "PII membrane" characterization in `conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md` §5.3 and `008a-conductor-recipe-surface-amendment.md` (both patched in the same change).

## 0. The security model (authoritative framing — owner 2026-06-23)

Before the membrane discussion, the architecture itself must be stated correctly, because it is the actual security boundary:

- **Fae runs on a local model (Gemma). She is local, private, and the coordinator.** All routing decisions — *what to delegate, to whom, and with what scope* — are reasoned locally, on-device. Her memory and the conversation context never leave the machine for the purpose of *making the routing decision*. **She is the boss.** That is where the security lies.
- **Other agents are tools she coordinates, not peers she pipes data to.** ACP harnesses the user has installed (Claude Code, Codex, Gemini CLI, Copilot, …) and cloud models reached via user-provided API keys are *capabilities Fae exercises under her local judgment*. They extend Fae's reach; they do not become Fae.
- **Cloud coordination is Fae-mediated delegation, not a data firehose.** Fae decides the scoped task each agent sees. A cloud agent receives what Fae chose to send for that specific delegated sub-task — closer to "I'll ask my lawyer about this specific clause" than "here is my whole life, advise me." The full conversational context stays with Fae (local); the delegate sees the slice.
- **The membrane is defense-in-depth, not the authority.** It is a credential/secret safety net that catches accidental leaks (an API key pasted into a prompt, a private key in context). It is a useful layer; it is not, and was never intended to be, the trust boundary itself. The trust boundary is Fae being local.

This framing matters because an earlier draft of this record over-rotated on the membrane's limitation and read as "cloud is dangerous, lock it down." That is the wrong read. The architecture is sound: a privacy-first companion whose coordinator is local and exercises cloud agents as scoped tools is a legitimate, trustworthy design. The Stage 3 question is **not** "is cloud egress safe" — it is **"what is the right default coordination reach for a privacy-first companion?"** (answered in §2: pure-local).

## 1. The membrane's real coverage (a layer within the model above — verified in source)

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

## 2. What this means for the default posture (the real Stage 3 question)

Re-stated with the §0 framing: cloud coordination is legitimate *because Fae mediates it*. So the Stage 3 question is **not** "is cloud egress safe" (the architecture answers yes, Fae-mediated). It is **"what coordination reach should Fae exercise by default for a privacy-first companion?"**

The owner's answer (2026-06-23): **pure-local by default.** Rationale that holds under the corrected model:

- **The product's identity is local-first.** ADR-003 (*"Fae's core promise is privacy — all intelligence runs on the user's Mac… Complete privacy — no data leaves the device"*; status: *remains active and implemented*), ADR-001 (*"Local-only privacy — all inference on-device"*), ADR-007 (the user *"owns all intelligence"*). The default should match the identity. A user who has not chosen to extend Fae's reach should not, by default, have a local-first companion that delegates their personal context to third-party clouds.
- **The membrane is defense-in-depth, not the decision-maker.** Under `all-available`, Fae *may* legitimately decide to delegate a task that carries personal content (a health question to Claude, say) — that is her call as boss. But the membrane will not catch that the content is personal, because it only catches secrets. So defaulting to `all-available` means *defaulting to Fae making cloud-delegation decisions about personal content before the user has opted into that reach.* That is a legitimate mode — it is not the right *default* for a companion whose identity is local-first.
- **No cloud-egress consent / disclosure UX exists today** (cloud was not a runtime surface until this track). So `all-available`-as-default would be *opt-out*, not opt-in. Defaulting to `pure-local` keeps the extension-of-reach an explicit, disclosed user choice.

This is a stronger and more accurate argument than "the membrane is insufficient." The architecture is sound; the default is a product posture, and the posture is: a privacy-first companion delegates nothing by default, and gains coordination reach only when the user chooses to extend it.

### Stage 3 status: DECIDED — pure-local default confirmed; all-available is opt-in

Stage 3 (the separate gated commit flipping `FAE_MODEL_MODE` default from `pure-local` to `all-available`) is **not proceeding** — owner acknowledgment 2026-06-23 confirmed the privacy-first posture: **`pure-local` remains the default**; `all-available` is an **explicit, disclosed opt-in.** The decision was made with the corrected premise on the table (Fae-as-coordinator is the boundary; the membrane is defense-in-depth for secrets; cloud coordination is legitimate but an extension of reach the user should choose).

Cloud egress therefore stays **opt-in** (`FAE_MODEL_MODE=all-available` or `local-symphony`) until/unless a future owner decision reverses this with a fresh disclosure-UX commitment. The mechanism work merged in M2 Stage 1 + NOTE-2 makes any of these choices safe to implement — the gates run identically regardless of default.

## 3. Scope the "egress-complete" claim so it isn't over-read

The universal egress claim holds for the daemon's **own** outbound calls today (conductor §5 path + the three agent commands). Two boundaries to state explicitly so it isn't mistaken for more:

1. **Post-spawn agent autonomy is outside the membrane by nature.** The conductor gates every prompt Fae *submits* to a Codex/Claude agent; but once spawned, that agent is an autonomous cloud-talking process — its own tool calls and direct network I/O are not (and cannot be) membrane-gated. Fae mediates the agent's filesystem via `PathPolicy`; it cannot mediate the agent's direct cloud chatter. **Acceptable** (provisioning the agent = trusting it), but it belongs in the threat model, not implicit.
2. **Future daemon-side tools are new egress surfaces.** `web_search` / `fetch_url` live in the Swift tool registry today; the daemon "is tool-aware but executes nothing." When **P7 / D3** (`docs/plans/cross-platform-completion-roadmap-2026-06-18.md`) lands a daemon-side ToolHost, those become fresh egress paths that **must route through the same gate pipeline** (mode cap → membrane → provisioning). **Flagged here so it is not rediscovered the way `agent.session_start` was** — i.e., assumed-fine until a review catches it as an ungated surface. The P7 plan should carry a "daemon tool egress must gate through `assert_*_egress_gates`" acceptance item.

## 4. What this does NOT change

- **The merge is correct and stays.** M2 Stage 1 + NOTE-2 are sound egress-gating work. The correction is about the *scope of what the membrane catches* and the *default posture*, not about whether the gating mechanism is safe. It is safe — for credentials, and for preventing unauthorized egress under `pure-local`. The mechanism is exactly what makes any default choice (including the recommended opt-in) safe to ship.
- **The gate pipeline order, the spy-tested invariants, and the fail-closed behavior all stand.** They prevent *secret* leakage and *unauthorized* egress; they do not (and were never going to) prevent personal-content egress under an operator-enabled cloud mode. That is a posture decision, not a mechanism defect.
- **MetaOpt / ADR-008a** is independently reviewable (see this change's ADR-008a v2 patch) and is not blocked by the Stage 3 hold.
