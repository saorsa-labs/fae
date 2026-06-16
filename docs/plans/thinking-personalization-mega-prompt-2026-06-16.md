# Mega-prompt — personalization-through-thinking + pill thinking UX (handoff 2026-06-16)

Paste this into a fresh session. It is self-contained; verify everything against the repo +
the bench rather than trusting this doc blindly (dev-agents have fabricated completion reports —
**always check against `git diff` and real command output**).

---

## Objective

Make Fae's **personal LoRA surface through her THINKING-enabled chat turns**, and make the **pill
show a "thinking" state** while she reasons. Owner decision (2026-06-16): **thinking STAYS ON** —
accuracy ≫ speed (Fae's core: "correct over fast"); the pill thinking-state is the feedback. Do
**not** suppress Gemma's reasoning.

Two threads:
- **Thread 1 — training/template alignment** (substantive): personalization must land in the
  *post-thinking* answer position when served via llama-server `--jinja`.
- **Thread 2 — pill thinking-state UX** (smaller, visible): parse the thinking span from the
  stream → "Fae is thinking…" → stream/speak the answer after.

Do the shared investigation (§"Served thinking format") ONCE first; it feeds both threads.

---

## Where we are (branch `llamacpp-serving-adapter`, NOT pushed; based on ACP commit `101146cd`)

The cross-platform **serving lane** and **producer** are built + verified + committed. The
train→serve→personalize loop is PROVEN end-to-end (via `/completion`); it does NOT yet surface
through the thinking-enabled `--jinja` chat endpoint (the template mismatch this prompt fixes).

Commits (newest first): `04ceb3c6`/`c3ff6265` C2 producer · `f63b4c2e`/`41157018` engine.reload ·
`8880dd4b`/`b7477a2f` engine.set_adapter_scale · `1ea00df7`/`e583b517` per-request LoRA scale ·
`32b6bb4e` LlamaServerAdapter · `267d84b6` design+gaps docs.

**Serving (Rust, `crates/`):**
- `crates/fae-engine/src/llamacpp_adapter.rs` — `LlamaServerAdapter` (OpenAI HTTP/SSE → `ChatEvent`):
  `connect`(attach URL) / `spawn`(supervise child, kill-on-drop) / `with_lora` / `reload_adapter`
  (restart sidecar with new `--lora`, same port) / `set_adapter_scale`. `build_chat_body` emits
  `lora:[{id,scale}]` and `reasoning_format:"none"` (keeps thinking inline in `content` for
  self-parse). Sidecar launched with `--jinja --reasoning-format none -fa on`.
- `crates/fae-daemon/src/main.rs` — `build_engine` routes to llama.cpp via `FAE_ENGINE=llamacpp` +
  `FAE_LLAMA_*` env (`FAE_LLAMA_SERVER_URL` to attach, or `FAE_LLAMA_MODEL_GGUF`/`_LORA_GGUF`/
  `_MMPROJ`/`_BIN`/`_PORT`/`_CTX`/`_NGL` to spawn; `FAE_LLAMA_HAS_LORA=1` on attach).
- Daemon protocol: `engine.set_adapter_scale {scale}` + `engine.reload {personal_adapter}`, gated
  on new `Scope::ModelManagement` (`crates/fae-control-plane/src/lib.rs`), dispatched in
  `crates/fae-daemon/src/session.rs`.
- Examples: `crates/fae-engine/examples/llama_smoke.rs` (stream a turn; `FAE_LLAMA_LORA_SCALE`,
  `FAE_SMOKE_MAX_TOKENS`), `crates/fae-engine/examples/llama_reload.rs` (spawn→reload→serve).
- 70 tests pass; `mistralrs` untouched (retire = gap B4, later).

**Producer (Python skill, macOS app resources):**
- `native/macos/Fae/Sources/Fae/Resources/Skills/training-orchestrator/scripts/train_peft.py` —
  portable `peft`+`transformers` LoRA SFT trainer (device-auto MPS/CUDA/CPU). Reads
  `sft_export.jsonl` (`{messages:[...]}` per line), formats with `apply_chat_template`, LoRA on
  `language_model.*` attn/MLP only. **This is where Thread 1's format change goes.**
- `.../scripts/convert_to_gguf.py` — PEFT → GGUF via llama.cpp `convert_lora_to_gguf.py` (resolves
  base config OFFLINE from the HF cache snapshot; `--base-model-id` needs network+`requests`, avoid).
- `.../MANIFEST.json` — skill integrity checksums (recompute with `shasum -a 256` after editing any
  script, per CLAUDE.md skill contract, or the SkillIntegrity test fails).

Full status: `docs/architecture/open-gaps-2026-06-16.md` (§B serving, §C training) and
`docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md` (design + §A validation). Memory:
`project_crossplatform_training`.

---

## The bench (`~/llama-spike/`) — reuse it, don't rebuild

- `llama.cpp/` — checkout @ `a182490`, **Metal release build** at `build/bin/llama-server` +
  `build/bin/llama-cli`; `convert_lora_to_gguf.py` + `gguf-py/` present.
- `gguf/gemma-4-E4B-it-Q4_K_M.gguf` (5 GB base) · `gguf/mmproj-gemma-4-E4B-it-bf16.gguf` (946 MB,
  audio Conformer) · `gguf12b/gemma-4-12b-it-UD-Q4_K_XL.gguf` (6.9 GB, production tier).
- `personal-c2b.gguf` (the verified C2 personal adapter), `peft-c2b/` (its PEFT source),
  `sft_test.jsonl` (4 chat-format examples teaching "MOONLIT-HERON").
- `test_server2.py`, `train_lora.py` (spike harnesses).
- HF cache already has `google/gemma-4-E4B-it` (PEFT base) + `google/gemma-4-12B-it`.

Run a server: `~/llama-spike/llama.cpp/build/bin/llama-server -m <gguf> --lora <personal.gguf>
--lora-init-without-apply --jinja --reasoning-format none -fa on -ngl 99 -c 4096 --host 127.0.0.1
--port <p>`. Per-request `{"lora":[{"id":0,"scale":0|1}]}` toggles base↔personalized.

---

## Shared investigation FIRST: what is the served thinking format?

The C2 adapter personalizes via `/completion` in its *trained* format, but NOT via the `--jinja`
**chat** endpoint, because Gemma's served turn opens with a thinking span (`<|channel>thought …`,
Harmony-style — NOT `<think>`) before the answer, which the answer-only training didn't match.

1. Dump the GGUF's embedded chat template and a real served turn. Compare to transformers'
   `AutoTokenizer.from_pretrained("google/gemma-4-E4B-it").apply_chat_template(...)`. Identify the
   exact thinking-span open/close markers and where the answer begins. (Watch for template drift
   between transformers and llama.cpp — prefer formatting via the SERVED template.)
2. Confirm with a server: send a normal chat turn, capture `content` (with `--reasoning-format
   none` thinking is inline) — note the literal markers.

This output drives both threads.

---

## Thread 1 — personalization surfaces through thinking (training-side)

Make SFT examples match the served, thinking-enabled template so the personalized answer lands
in the **post-thinking** position.

Tasks:
- **Thinking-trace source.** Decide: (a) **capture** Fae's real thinking at conversation time (the
  daemon already generates it — store the thinking span alongside `assistant_text` in the episode /
  `build_dataset.py` output), or (b) **synthesize** a short thinking block that ends in the known
  answer during data export. (a) is truer; (b) unblocks immediately. Likely: support both.
- **Format change in `train_peft.py`** (and the data shape from
  `training-data-bridge/scripts/build_dataset.py` / `export_data.py`): assistant turn =
  `thinking → answer`, formatted with the SERVED template (not the bare answer). Keep masking the
  prompt; train on the thinking+answer target. Keep LoRA on `language_model.*` attn/MLP only.
- **Use a NON-adversarial personalization for the signal test.** "secret project codename" is
  pathological — Gemma is trained to refuse secrets, which fights the LoRA. Use a benign learned
  fact/preference/style (e.g. "Fae's owner prefers metric units", a made-up benign biographical
  fact) so the signal is clean.
- **Verify (done-criteria):** train (`train_peft.py`) → `convert_to_gguf.py` → serve with
  `--jinja` (thinking ON) → **chat** endpoint, temp 0: scale 1 yields the personalized answer
  AFTER a thinking span; scale 0 does not. Then re-verify on the **12B-UD** base (production tier).
  Show verbatim transcripts.
- Note the **Unsloth NVIDIA lane** remains a later drop-in over this same PEFT path (untested here —
  no CUDA; same artifact format). Don't block on it.

Files: `train_peft.py`, `build_dataset.py`/`export_data.py`, the bench. Recompute MANIFEST
checksums after editing skill scripts.

---

## Thread 2 — pill shows "thinking" state

While Fae reasons, the pill shows "Fae is thinking…"; the answer streams/speaks after; the
thinking is NOT spoken.

Tasks:
- **Split thinking vs answer in the stream.** The thinking arrives as `content` tokens (inline,
  `--reasoning-format none`) bracketed by the markers from the shared investigation
  (`<|channel>thought …`, Harmony-style — NOT `<think>`). Detect the thinking span and emit a
  "thinking" UI event; route the post-thinking text to the answer + TTS. Prefer doing this
  **daemon-side or in the orb host** over deep Swift (cross-platform drive — keep Swift thin).
- **`ThinkTagStripper`** (`Pipeline/TextProcessing.swift`) currently handles `<think>…</think>`;
  extend it (or its equivalent) to the Gemma `<|channel>thought` channel markup, and make it emit a
  thinking-state signal rather than only stripping.
- **Orb pill state.** Drive an orb "thinking" mode/feeling (`OrbTypes.swift` → the Rust orb host
  `native/rust/fae-ui-shell`) during the thinking span. (Related: memory note
  `reference_orb_static_when_finished` + `reference_orb_thinking_strand_bug` — the orb's
  thinking/speaking state handling has known bugs; check them.)
- **Verify:** a real turn through the daemon (or the bench server via the Swift pipeline) →
  pill shows "thinking" during the span → answer appears + TTS speaks only the answer (no thinking
  spoken). Capture a short transcript / GIF.

Files: `Pipeline/TextProcessing.swift`, `Pipeline/PipelineCoordinator.swift`,
`ML/DaemonLLMEngine.swift` (stream), `OrbTypes.swift`, `native/rust/fae-ui-shell/`.

---

## Cross-cutting rules / gotchas (learned this session)

- **`env -u RUSTFLAGS`** for ALL crate builds — vendored candle's unused-import breaks `-D warnings`
  (goes away with mistral.rs retirement, gap B4). Validate: `cd crates && cargo fmt … && cargo
  clippy -p <crate> --all-targets -- -D warnings && cargo nextest run -p <crate>`.
- **Skill scripts** → recompute `MANIFEST.json` SHA-256 checksums after edits.
- **uv**: `uv run --isolated --no-project --with …` to avoid a stray broken `~/.venv`. `apply_chat_template`
  needs `jinja2`. Never pip; uv only.
- **context-mode hook intercepts `curl`/`wget`** — drive HTTP from Python `urllib` in tests.
- **MLX ops crash under `swift test`**; QUIT the dev app before local `swift test`; the Swift suite
  is heavy (don't run it casually). The Rust crate tests are fast + safe.
- **Verify against `git diff` + real output.** Dev-agent subagents have fabricated reports (0 tool
  calls, invented diffs) — gate every claim on verbatim evidence.
- Production base tier = **Gemma 4 12B Unsloth UD-Q3/Q4_K_XL** (validated, ~8 GB); E4B is the
  fast bench model. Validate Thread 1 on 12B before calling it done.

---

## Suggested order

1. Shared investigation (served thinking format) — 1 short spike.
2. Thread 1 (training alignment + benign-fact verification on E4B, then 12B).
3. Thread 2 (pill thinking-state) — can run in parallel once the markers are known.
4. Commit each on `llamacpp-serving-adapter`; update `open-gaps-2026-06-16.md` + memory + Obsidian.

Done when: a normal **thinking-enabled chat turn** through llama-server shows the personalized
answer after the thinking span (Thread 1), and the **pill displays "thinking"** during it with only
the answer spoken (Thread 2) — both with verbatim evidence, on the 12B tier.
