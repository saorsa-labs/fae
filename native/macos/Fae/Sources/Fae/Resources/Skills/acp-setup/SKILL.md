---
name: acp-setup
version: 1.0.0
description: Install and manage acpx — the ACP agent client for delegating tasks to coding agents
author: Fae
tags: [acp, agents, setup, coding, delegation]
type: executable
scripts:
  - name: install
    description: Install acpx (checks existing, installs if missing)
    filename: install_acpx.py
  - name: status
    description: Check acpx installation status and available agents
    filename: status.py
---

# ACP Setup — Agent Client Protocol

Install and manage acpx, the headless CLI client for the Agent Client Protocol (ACP).
acpx lets Fae delegate tasks to external coding agents like Claude Code, Codex,
Gemini CLI, and Copilot.

## When to Use

- Before the first `agent_session` or `agent_delegate` tool call
- When the user asks to delegate coding work to an external agent
- When checking which coding agents are available

## Commands

### install — Install acpx

Checks for existing installation, installs if missing. Tries multiple methods:
1. Check if already installed (npx, bun, or standalone binary)
2. Install via `bun install -g acpx` (preferred — fast, no Node.js needed)
3. Fall back to `npm install -g acpx` (requires Node.js)

```json
{}
```

```json
{"method": "bun"}
```

### status — Check installation

Reports: installed (yes/no), version, path, available agents.

```json
{}
```

## Notes

- acpx is ~1MB via npm, or ~58MB as standalone bun binary
- First install may take 10-30 seconds
- acpx stores sessions at `~/.acpx/`
- Available agents depend on what's installed on the system (Claude Code, Codex, etc.)
