---
name: forge
description: Tool creation workshop. Create, compile, test, and release Zig programs, Python scripts, and WASM modules as shareable skills.
metadata:
  author: fae
  version: "1.0"
---

You are operating Fae's Forge -- the tool creation workshop where you help the user create, build, test, and release custom tools that become installable Fae skills.

## Overview

The Forge turns ideas into working tools. You scaffold projects, write code, compile binaries, run tests, and package everything into a skill that Fae (or other users) can install.

**Supported languages:**
- **Zig** -- compiles to native ARM64 macOS binaries and optionally WebAssembly (WASM)
- **Python** -- scripts executed via `uv run --script` with inline dependency declarations
- **Both** -- hybrid projects with Zig for performance-critical parts and Python for glue

## Directory Layout

```
~/.fae-forge/
  workspace/{tool-name}/     # Active development projects (git repos)
  tools/{tool-name}/         # Released, installable skill packages
  bundles/                   # Git bundle archives for sharing
  registry.json              # Index of all released tools
```

## Available Scripts

### init
Scaffold a new tool project with proper directory structure, templates, and git initialization.

Usage: `run_skill` with name `forge` and input:
```json
{"script": "init", "params": {"name": "my-tool", "lang": "zig", "description": "One-line description"}}
```

Parameters:
- `name` (required): tool name, lowercase with hyphens (e.g., `json-formatter`, `image-resize`)
- `lang` (required): `"zig"`, `"python"`, or `"both"`
- `description` (optional): one-line description of what the tool does

### build
Compile a tool project. For Zig projects, produces native ARM64 and/or WASM binaries. For Python, runs syntax and dependency checks.

Usage: `run_skill` with name `forge` and input:
```json
{"script": "build", "params": {"name": "my-tool", "target": "native", "mode": "debug"}}
```

Parameters:
- `name` (required): tool name (must exist in workspace)
- `target` (optional): `"native"` (default), `"wasm"`, or `"both"`
- `mode` (optional): `"debug"` (default) or `"release"`

### test
Run tests for a tool project. Zig uses `zig build test`, Python uses pytest or basic import check.

Usage: `run_skill` with name `forge` and input:
```json
{"script": "test", "params": {"name": "my-tool", "verbose": true}}
```

Parameters:
- `name` (required): tool name
- `verbose` (optional, bool): include full test output

### release
Build in release mode, package as an installable skill, git tag, and create a shareable bundle.

Usage: `run_skill` with name `forge` and input:
```json
{"script": "release", "params": {"name": "my-tool", "version": "1.0.0"}}
```

Parameters:
- `name` (required): tool name
- `version` (required): semver string (e.g., `"1.0.0"`)
- `sign` (optional, bool, default true): GPG-sign the git tag

## Workflow

The standard flow for creating a new tool:

1. **Init**: `run_skill forge init` with name and language
2. **Write code**: Use `read`/`write`/`edit` tools to develop the tool in the workspace
3. **Build**: `run_skill forge build` to compile and check for errors
4. **Test**: `run_skill forge test` to run the test suite
5. **Iterate**: Fix issues, rebuild, retest until green
6. **Release**: `run_skill forge release` with a version to package and register

## How Released Tools Become Skills

When you release a tool, the release script creates a complete skill package at `~/.fae-forge/tools/{name}/` with:
- `SKILL.md` (skill metadata and instructions)
- `MANIFEST.json` (capabilities, SHA-256 integrity checksums)
- `bin/` (native and/or WASM binaries for Zig tools)
- `scripts/run.py` (wrapper that invokes the right binary or Python script)

The user can then copy or symlink this into their Fae skills directory to make it available.

## Prerequisites

- **Zig**: install via `zb install zig` (required for Zig projects)
- **wasmtime**: install via `zb install wasmtime` (optional, for running WASM modules)
- **git**: required for version control and release bundles (pre-installed on macOS)
- **uv**: required for Python script execution (pre-installed with Fae)

## Tips for the LLM

- Always `init` before trying to `build` or `test` -- the workspace must exist first.
- Use `build` frequently during development to catch errors early.
- For Zig tools that process data, use stdin/stdout JSON pipes to match the Fae skill protocol.
- The `release` script handles everything: release build, packaging, tagging, and registry update.
- If `zig` is not found, suggest the user run `zb install zig`.
- WASM builds require the `wasm32-wasi` target -- Zig includes this by default.
- Tool names must be lowercase with hyphens only -- no underscores, no uppercase.
