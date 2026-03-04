---
name: toolbox
description: Local tool registry. List, search, install, verify, and uninstall forge-built tools. Manages ~/.fae-forge/tools/ and registry.json.
metadata:
  author: fae
  version: "1.0"
---

The toolbox manages Fae's local tool registry at `~/.fae-forge/`. Every tool installed through the toolbox is a skill directory containing a `SKILL.md` entry point, optional `bin/` or `scripts/` folders, and an optional `MANIFEST.json` for integrity verification.

## Directory Layout

```
~/.fae-forge/
  registry.json          # Tracks all installed tools with metadata
  tools/                 # Installed tool directories (one per tool)
    my-tool/
      SKILL.md
      MANIFEST.json
      scripts/
      bin/
  bundles/               # Cached .bundle files for resharing with peers
  peers.json             # Known peer catalog endpoints (for mesh search)
```

## Registry

`registry.json` is the source of truth for installed tools. Each entry records:
- `name`, `version`, `description`, `lang` (python, binary, instruction)
- `sha256` — hash of the original bundle or directory snapshot
- `installed` — ISO 8601 date
- `source` — `local`, `peer`, or `manual`
- `path` — absolute path to the installed tool directory

## Available Scripts

### list
List all installed tools. Shows name, version, description, and source. Detects orphan tools present on disk but missing from the registry.

Usage: `run_skill` with name `toolbox` and input `{"script": "list"}`.

Optional params: `verbose` (bool) — include file paths and sizes.

### install
Install a tool from a git bundle file, a directory, or a prepared archive.

Usage: `run_skill` with name `toolbox` and input `{"script": "install", "params": {"source": "/path/to/tool.bundle"}}`.

Params:
- `source` (required) — path to a `.bundle` file or a directory containing a skill layout
- `name` (optional) — override the tool name (defaults to directory/bundle name)
- `verify` (bool, default true) — verify MANIFEST.json checksums after install
- `force` (bool, default false) — overwrite an existing installation

### search
Search for tools by keyword in the local registry or across known peers.

Usage: `run_skill` with name `toolbox` and input `{"script": "search", "params": {"query": "audio"}}`.

Params:
- `query` (required) — search term
- `scope` (optional) — `local` (default), `peers`, or `all`

### verify
Verify the integrity of an installed tool by checking MANIFEST.json checksums and optional git signatures.

Usage: `run_skill` with name `toolbox` and input `{"script": "verify", "params": {"name": "my-tool"}}`.

Params:
- `name` (required) — tool name
- `check_signatures` (bool, default true) — also verify git tag signatures if available

### uninstall
Remove an installed tool from the registry and disk. Optionally keeps the bundle for resharing.

Usage: `run_skill` with name `toolbox` and input `{"script": "uninstall", "params": {"name": "my-tool"}}`.

Params:
- `name` (required) — tool name
- `keep_bundle` (bool, default true) — preserve the .bundle file in bundles/

## When to Use

- User asks "what tools do I have?" or "list my tools" — use `list`
- User asks "install this tool" or provides a bundle/directory — use `install`
- User asks "find a tool for X" or "search for X" — use `search`
- User asks "is this tool safe?" or "check tool integrity" — use `verify`
- User asks "remove this tool" or "uninstall X" — use `uninstall`
- After installing a tool, offer to activate it as a Fae skill
