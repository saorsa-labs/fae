# Fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is a **local, private, cross-platform head butler**: an orb on your screen backed by a tool-calling brain that runs entirely on your own hardware. She listens, remembers, executes, and improves herself overnight — and nothing leaves your machines.

Fae is not a hugely-capable chatbot. She is a hugely-**personalised** agent: a modest local model, a deep tool and skill system, a durable memory, and a nightly retraining loop that adapts her to you specifically.

**Website:** [the-fae.com](https://the-fae.com)

## The strategy in 60 seconds

- **Orb-first UI.** The orb (a Rust UI shell) is the only product surface — transcript panel, approval cards, settings. No dashboard, no chat window sprawl.
- **Gemma 4 tool-calling brain, served by a Rust daemon.** `fae-daemon` (in `crates/`) runs Gemma 4 E4B through **mistral.rs** (Metal/CPU), with a **llama.cpp fallback for Vulkan-class hardware** — the cross-platform path to Linux and Windows. On macOS the Swift MLX engine remains as fallback and training substrate.
- **Nightly personal retraining.** Every night Fae mines the day's feedback, fine-tunes a personal LoRA adapter, and **only deploys if benchmarks pass** (FaeBenchmark gate + external review + rollback). Your Fae gets better at being *your* Fae.
- **Skills.** 29 built-in skills, write-your-own via the **forge** skill (scaffold → compile → test → release), and subscriptions to secure skill repos — all under signed manifests with SHA-256 integrity checks.
- **x0x: your machines, one harness.** [x0x](https://github.com/saorsa-labs/x0x) (v0.23.1) is a post-quantum encrypted gossip network for agents. It connects your own machines into a single Fae harness, and connects your Fae to other agents to communicate and collaborate.
- **Voice identity is the security model.** Only recognised voices get tool access. Not settings toggles — speaker verification (ECAPA-TDNN x-vectors on the Neural Engine).
- **Local by default.** Models, memory, voice prints, training data, backups: all on disk, all yours. SQLite memory, Git-based vault backup, no cloud dependency.

## Architecture

```
                you (voice / text)
                       │
        ┌──────────────▼───────────────┐
        │      Orb — Rust UI shell      │   the only product UI:
        │  orb · transcript · approval  │   breathes while thinking,
        │  cards · settings panels      │   glows while working
        └──────────────┬───────────────┘
                       │ host bridge
        ┌──────────────▼───────────────────────────────┐
        │            Fae app (Swift, macOS)             │
        │  voice pipeline: VAD → speaker ID → STT → TTS │
        │  memory (SQLite ANN+FTS5) · scheduler · tools │
        │  skills · nightly improvement loop · vault    │
        └────────┬──────────────────────────┬──────────┘
                 │ NDJSON / Unix socket     │
        ┌────────▼────────────┐   ┌─────────▼─────────────┐
        │  fae-daemon (Rust)  │   │   x0x (PQC P2P net)    │
        │  Gemma 4 E4B brain  │   │  ML-DSA-65 identity ·  │
        │  mistral.rs primary │   │  your other machines · │
        │  llama.cpp fallback │   │  other agents          │
        │  (Vulkan-class HW)  │   └────────────────────────┘
        │  MLX fallback (mac) │
        └─────────────────────┘
```

Voice in, judgment in the middle, tools out. The daemon owns inference behind a fail-closed control plane (`fae-control-plane`): capability scopes, per-command authorization, hashed session tokens, audited boundaries. Peer traffic passes a typed envelope gate (`fae-envelope-gate`) — no free-form peer text ever reaches the LLM, memory, or tools.

## Quick start

Prerequisites: Apple Silicon Mac, Xcode toolchain, [`just`](https://github.com/casey/just), Rust toolchain (for the orb shell and daemon).

```bash
git clone git@github.com:saorsa-labs/fae.git
cd fae
just --list                          # all recipes

just check                           # build + test (Swift app)
just check-ui-shell                  # validate the Rust orb shell
cd crates && just check && cd ..     # daemon workspace: fmt + clippy -D warnings + tests

source ~/.secrets && just run-dev    # DEV profile: orb host embedded, isolated config/memory
source ~/.secrets && just run-native # production launch
```

Both `run-dev` and `run-native-with-ui-shell` build and embed the Rust orb host into the app bundle. First run downloads models (~8 GB) — the orb shows progress throughout.

To route conversation turns through the Rust daemon brain, enable `llm.useDaemonEngine` in config (Gemma 4 E4B via mistral.rs). If the daemon is unavailable, Fae fails over to the in-process MLX engine.

## The brain

| Layer | What runs | Notes |
|---|---|---|
| LLM (primary) | Gemma 4 E4B via `fae-daemon` + mistral.rs | Tool calling, 128K context; fail-closed `models.lock` (SHA-256) |
| LLM (portable) | llama.cpp adapter | Fallback for Vulkan-class hardware; the Linux/Windows path |
| LLM (macOS fallback) | Qwen3.5 via MLX (Swift) | Also the LoRA training substrate |
| STT | Qwen3-ASR (MLX) | Plus post-ASR vocabulary correction learned from your corrections |
| TTS | Kokoro-82M (MLX) | Streaming, sentence-queued, barge-in always on |
| Speaker ID | ECAPA-TDNN (Core ML) | The security model — voice identity gates all tool access |
| Vision | SmolVLM2 (MLX) | Presence detection, screen context, on-demand analysis |

## Memory and self-improvement

- **Memory**: SQLite with hybrid recall (ANN vectors + FTS5 lexical), automatic capture after every turn, an entity graph for people/orgs/places, and explicit remember/forget control. `~/Library/Application Support/fae/fae.db`.
- **Nightly improvement cycle** (03:00): collect implicit feedback → meta-optimize directives/config/skills → export SFT/DPO data → train a personal LoRA adapter → **evaluate against FaeBenchmark** → external review gate → propose or deploy. Regressions roll back automatically; "undo the last change you made to yourself" works by voice.
- **Git Vault**: rolling backup of memory, config, soul, and skills at `~/.fae-vault/` — survives app deletion.

## Skills

Skills are markdown-plus-scripts packages with signed manifests (SHA-256 checksums, schema-versioned). Three lanes:

1. **Built-in** — 29 ship with Fae: voice identity, proactive awareness, morning briefings, overnight research, email triage, file organisation, channel integrations (Discord/WhatsApp/iMessage), training orchestration, and more.
2. **Write your own** — the **forge** skill scaffolds, compiles, tests, and releases new tools (Zig/Python); **toolbox** registers them locally; **mesh** shares them with your other machines.
3. **Subscribe** — secure skill-repo subscriptions extend the same integrity model to third-party skill collections.

## x0x — one harness, many machines

[x0x](https://github.com/saorsa-labs/x0x) (`../x0x`, v0.23.1) is Saorsa Labs' post-quantum agent network. What Fae gets from it:

- **Automatic agent identity** — an ML-DSA-65 keypair generated on first start; no accounts, no registration.
- **Shareable identity cards** — `x0x://agent/…` strings anyone can import in one step.
- **Signed gossip pub/sub** — every message carries an ML-DSA-65 signature; unsigned or invalid messages are dropped, never rebroadcast.
- **End-to-end post-quantum direct messaging** and **file sharing** between agents.
- **Partition tolerance** — no global-DHT dependence: if your machines can reach each other, your data keeps working, even when the wider network can't be reached.

This is how Fae becomes a **conductor**: your Mac, your Linux box, and your homelab become one Fae harness, and your Fae can collaborate with other people's agents under explicit, capability-scoped grants. See `docs/architecture/conductor-positioning-and-scope-2026-06-05.md`.

## Privacy and security

- **Local by default.** Inference, memory, voice prints, and training all happen on your hardware.
- **Voice identity gates tools.** Pre-enrollment: no tool calls. Enrolled owner: full access. Guests: nothing unless you grant it.
- **Damage control.** Catastrophic bash operations are blocked or require confirmation; credential paths are protected; pre-mutation file snapshots make actions undoable.
- **Fail-closed daemon.** Model weights verified against `models.lock` (SHA-256); every daemon command authorized per-capability and audited.
- **Typed peer boundary.** x0x peer traffic is schema-checked and signature-verified before anything touches the LLM.

## Documentation

| Topic | Where |
|---|---|
| Strategy + cleanup mandate | `docs/architecture/great-cleanup-2026-06-11.md` |
| Orb-first UI decision | `docs/adr/009-rust-orb-ui-shell.md`, `docs/architecture/butler-ui-redesign-2026-06-05.md` |
| Rust daemon (crates/) | `crates/README.md`, `docs/architecture/headless-core-impl-plan-2026-06-01.md` |
| Conductor / x0x integration | `docs/architecture/conductor-positioning-and-scope-2026-06-05.md` |
| Memory system | `docs/guides/Memory.md` |
| Voice identity | `docs/guides/voice-identity.md` |
| Self-improvement loop | `docs/guides/self-improvement-and-proactive-architecture.md` |
| Release validation | `docs/checklists/app-release-validation.md` |
| ADRs (decision record) | `docs/adr/` |
| Superseded docs | `docs/archive/` |
| Changelog | `docs/CHANGELOG.md` |

## Platform status

| Platform | Status | Path |
|---|---|---|
| macOS (Apple Silicon) | Primary, shipping | Swift app + Rust orb shell + Rust daemon |
| Linux / Windows | In progress | `fae-daemon` + llama.cpp (Vulkan-class hardware); see `docs/architecture/cross-platform-go-nogo-2026-06-11.md` |
| iOS / iPadOS | Planned | Companion via x0x harness |

## Contact

- GitHub: [saorsa-labs/fae](https://github.com/saorsa-labs/fae)
- Email: david@saorsalabs.com
- License: Dual AGPL-3.0 / Commercial
