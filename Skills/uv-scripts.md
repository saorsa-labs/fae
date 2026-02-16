# UV Python Scripts

Use this skill when the user asks Fae to extend her own capabilities with small Python helpers (one-off utilities, data transforms, repo maintenance helpers, etc.) without modifying the Rust core.

## Goals

- Keep Rust as the secure minimal core.
- Put fast-changing automation into small, auditable scripts.
- Use `uv` for deterministic installs + execution (lockfile-driven, workspace-local).

## Storage Contract (Workspace-Local)

All Python helper code lives inside the current tool workspace boundary:

- Project root: `.fae/python/`
- Scripts: `.fae/python/scripts/*.py`
- Project files:
  - `.fae/python/pyproject.toml`
  - `.fae/python/uv.lock`

Never write or execute Python helper code outside the workspace boundary.

## Tool Requirements

- Editing scripts (when directories already exist): tool mode `read_write` (or higher).
- Initial setup (create directories, install `uv`, run scripts): tool mode `full` (or `full_no_approval`) because it needs `bash`.

## Execution Contract

Prefer a workspace-local `uv` binary if present:

- `.fae/bin/uv` (preferred, installer-managed)
- fallback: `uv` from `PATH`

Always run uv with `--directory .fae/python` so commands do not rely on `cd` or shell chaining:

- `.fae/bin/uv --directory .fae/python run python scripts/<name>.py -- <args...>`
- `uv --directory .fae/python run python scripts/<name>.py -- <args...>`

Notes:

- The `bash` tool may not allow shell chaining, pipes, redirects, or env-var expansion; keep each command single-purpose.
- If dependency sync or downloads may exceed the default tool timeout, set an explicit longer timeout for the `bash` call.

## Dependency Rules (Lockfile-First)

- Prefer project-managed deps in `.fae/python/pyproject.toml` + `.fae/python/uv.lock`.
- Add deps with uv (not pip):
  - `uv --directory .fae/python add <package>`
- Keep execution deterministic:
  - Use `uv --directory .fae/python run --frozen ...` for normal runs.
  - Use `uv --directory .fae/python sync --frozen` when you need to materialize the environment.
- If `uv` is missing, prefer using an installer-provided `.fae/bin/uv`. If none exists, you may bootstrap `uv` into `.fae/bin/uv` (see below) with explicit user approval.

## Bootstrapping `uv` (If Missing)

This is a high-risk operation (downloads and executes an installer). Always ask for explicit user approval before running these commands.

macOS ships with `/usr/bin/curl` by default, but still check.

Because the `bash` tool may block pipes/redirection, do NOT use `curl ... | sh`. Use a download-then-run flow:

1. Check for `uv`:
   - `.fae/bin/uv --version`
   - `uv --version`
2. Check prerequisites:
   - `command -v curl`
3. Create workspace-local directories:
   - `mkdir -p .fae/bin .fae/tmp .fae/python/scripts`
4. Download the official uv installer script:
   - `curl -LsSf -o .fae/tmp/uv-install.sh https://astral.sh/uv/install.sh`
5. Install into the workspace-local bin dir without modifying PATH:
   - `UV_NO_MODIFY_PATH=1 XDG_BIN_HOME=.fae/bin sh .fae/tmp/uv-install.sh`
6. Verify:
   - `.fae/bin/uv --version`

## Script Interface Rules

Python helpers must be:

- Non-interactive (no prompts).
- Deterministic for the same inputs.
- Small stdout (prefer machine-readable JSON for results).
- Strict about errors: non-zero exit + short error message on failure.

Recommended skeleton:

- `argparse` for CLI.
- `json` for structured input/output.
- Accept large inputs via file path args, not via huge stdout/stderr.

## Workflow (When Adding A New Helper)

1. Ensure the directory layout exists:
   - `mkdir -p .fae/python/scripts`
2. Ensure `.fae/python/pyproject.toml` exists (minimal metadata + deps).
3. Write the script to `.fae/python/scripts/<name>.py`.
4. If deps are needed, add them with `uv ... add ...`, then lock/sync using `--frozen`.
5. Run the helper via uv and validate the output.
6. If the helper is generally useful, document:
   - how to call it
   - expected inputs/outputs
   - any safety constraints
