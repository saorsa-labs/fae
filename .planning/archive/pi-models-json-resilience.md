# Pi models.json Resilience — Research & Design Notes

> Archived 2026-02-11. Not yet implemented — user has an alternative approach in mind.

## Problem Statement

`~/.pi/agent/models.json` is a shared config file that can be corrupted by manual edits or other tools. When corrupt:
1. `write_fae_local_provider()` fails (reads existing file with `?`)
2. Pi subprocess crashes on its own startup parsing
3. Entire coding pipeline breaks

## Current Architecture

### Key files:
- `src/llm/pi_config.rs` — reads/writes models.json
- `src/pi/engine.rs` — resolves model candidates, creates PiSession
- `src/pi/session.rs` — spawns Pi subprocess with `--provider` and `--model` CLI flags
- `src/startup.rs` — calls `write_fae_local_provider()` at line 355-359

### How Pi is spawned:
```
pi --mode rpc --no-session --provider fae-local --model fae-qwen3 --tools read,grep,find,ls,bash ...
```
Pi then looks up "fae-local" in `~/.pi/agent/models.json` to find the `baseUrl`.

### Pi installation:
- Installed as native binary via GitHub releases (badlogic/pi-mono)
- Currently aliased to `npx @mariozechner/pi-coding-agent@latest` on this machine
- No `--config-dir` or `--models-file` CLI override discovered
- No known env var to redirect config path

### Current models.json contents:
3 providers: `minimax`, `fae-local`, `z-ai` (with API keys)

## Explored Approaches

### Option A: Fae-managed HOME dir — REJECTED
Set `HOME` to `~/.fae/pi-home/` before spawning Pi so it reads from a different location.
**Problem:** Breaks Pi's other features (sessions, extensions, skills, auth) that live under `~/.pi/agent/`.

### Option B: Clean write in local-only mode — VIABLE
New `write_fae_only_config(path, port)` that writes a hardcoded config with only fae-local. No read, no merge. Used when `cloud_provider` is `None`.

### Option C: Separate config path — REJECTED
Pi reads from `~/.pi/agent/models.json` hardcoded. No env var override found. Requires upstream Pi changes.

### Option D: Validate and repair — VIABLE
Make `read_pi_config()` resilient: on parse failure, backup corrupt file, return empty.

### Recommended: B + D combined
- Local-only: write clean (no merge)
- Cloud: merge with resilient reading
- Changes in 3 files: pi_config.rs, startup.rs, engine.rs

## Key Code Locations

| Location | Purpose |
|----------|---------|
| `pi_config.rs:191-201` | `read_pi_config()` — strict JSON read |
| `pi_config.rs:203-251` | `write_fae_local_provider()` — read+merge+write |
| `pi_config.rs:253-270` | `remove_fae_local_provider()` — cleanup |
| `pi_config.rs:273-297` | `write_config_atomic()` — atomic temp+rename |
| `pi_config.rs:299-307` | `default_pi_models_path()` — always `~/.pi/agent/models.json` |
| `startup.rs:345-362` | `start_llm_server()` — calls write_fae_local_provider |
| `engine.rs:1040-1086` | `resolve_pi_provider_model()` — reads models.json for primary |
| `engine.rs:1088-1193` | `resolve_pi_model_candidates()` — reads models.json for all candidates |
| `engine.rs:1094-1095` | Already uses `.ok()` to swallow read errors (but loses data) |
| `session.rs:398-485` | `PiSession::spawn()` — builds Pi command with `--provider`/`--model` |

## Findings

- `resolve_pi_model_candidates()` already swallows errors with `.ok()` — corruption causes silent fallback
- `write_fae_local_provider()` uses `read_pi_config(path)?` — corruption is a hard failure
- Pi binary path: `~/.local/bin/pi` (Fae-managed) or system PATH
- Pi is spawned with full control over env vars via `Command::new()` in session.rs
- The `fae-local` provider config is always the same structure (hardcoded in `write_fae_local_provider`)
- `PiModelsConfig` uses `#[serde(flatten)]` for forward compatibility
