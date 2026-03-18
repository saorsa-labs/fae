---
name: uv-scripts
description: Create and run Python helper scripts for Fae using uv — workspace-local, deterministic, auditable utilities for one-off tasks.
metadata:
  author: fae
  version: "1.0"
---

Use this skill when you need to write small Python helpers to extend Fae's capabilities for one-off tasks — data transforms, repo maintenance, utilities — without modifying Fae itself.

## Core Principles

- Keep helper scripts small, focused, and disposable.
- Use `uv run --script` for deterministic, reproducible execution.
- Keep all code inside the workspace boundary: `.fae/python/`.
- Scripts must be non-interactive (no prompts) and produce machine-readable output.

## Directory Layout

```
.faerc/python/
  pyproject.toml      # Project metadata + dependencies
  uv.lock             # Locked dependency versions
  scripts/
    <name>.py         # Individual helper scripts
```

## Workflow

1. **Set up** (first time only):
   - Create `.fae/python/scripts/` if it doesn't exist.
   - Create `.fae/python/pyproject.toml` with `[project]` metadata.
   - Use `uv --directory .fae/python sync` to materialise the environment.

2. **Write a script** at `.fae/python/scripts/<name>.py`:
   ```python
   #!/usr/bin/env -S uv run --script
   # /// script
   # requires-python = ">=3.12"
   # dependencies = ["httpx"]
   # ///
   """One-line description."""

   import json
   import sys

   def run(params: dict) -> dict:
       # TODO: implement
       return {"ok": True, "result": "..."}

   if __name__ == "__main__":
       request = json.loads(sys.stdin.read())
       print(json.dumps(run(request.get("params", {}))))
   ```

3. **Execute** via the `bash` tool:
   ```
   uv --directory .fae/python run python scripts/<name>.py -- <args>
   ```
   Or with a frozen lockfile:
   ```
   uv --directory .fae/python run --frozen python scripts/<name>.py
   ```

4. **Add dependencies**:
   ```
   uv --directory .fae/python add httpx
   uv --directory .fae/python lock
   uv --directory .fae/python sync --frozen
   ```

## Script Requirements

- **Input**: Read JSON from stdin (`sys.stdin.read()`). Expect `{"params": {...}}`.
- **Output**: Write JSON to stdout (`print(json.dumps(...))`).
- **Errors**: Non-zero exit code + `{"ok": false, "error": "..."}` on stdout.
- **No prompts**: Never use `input()` or other interactive functions.
- **Deterministic**: Same inputs → same outputs, every time.

## Tool Mode

- Writing/editing scripts: `read_write` tool mode (Fae can use `read` and `edit` tools).
- First-time setup (creating directories, installing uv): `full` tool mode (needs `bash`).

## Bootstrapping uv

If `uv` is not available, ask for explicit user approval first, then:
```
curl -LsSf -o /tmp/uv-install.sh https://astral.sh/uv/install.sh
sh /tmp/uv-install.sh --install-dir ~/.local/bin
```
macOS default curl is fine. Always prefer a pre-installed `uv` over bootstrapping.
