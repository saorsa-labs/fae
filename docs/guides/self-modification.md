# Self-Modification Guide

Fae can modify her own behavior, communication style, and capabilities at your request. Changes persist across conversations.

## Personality Tuning (SelfConfigTool)

The `self_config` tool lets Fae save personality preferences that apply to every future interaction.

### How It Works

When you say something like "be more cheerful" or "always greet me by name", Fae uses the `self_config` tool to persist that preference. The preferences are stored as a directive file at:

```
~/Library/Application Support/fae/directive.md
```

This file is loaded on every prompt assembly, so changes take effect immediately on the next response. The directive is for critical overriding instructions — it is usually empty unless you have something important Fae must always follow.

### Actions

| Action | Description |
|---|---|
| `get_directive` | Read current directive |
| `set_directive` | Replace all directives with new text |
| `append_directive` | Add a new directive without removing existing ones |
| `clear_directive` | Remove all directives, revert to defaults |

Legacy action names (`get_instructions`, `set_instructions`, `append_instructions`, `clear_instructions`) are still supported as aliases.

### Examples

**Setting a communication style:**
> "Fae, be more concise in your responses."

Fae calls `self_config(action: "append_directive", value: "Be more concise — keep responses to 1-2 sentences unless the topic requires more detail.")`.

**Overriding all preferences:**
> "Fae, forget all my style preferences and start fresh."

Fae calls `self_config(action: "clear_directive")`.

**Checking current preferences:**
> "Fae, what are my current style preferences?"

Fae calls `self_config(action: "get_directive")` and reads back the result.

## Skills (v2 — Agent Skills Standard)

Fae uses a directory-based skill system following the [Agent Skills](https://agentskills.io/specification) open standard (used by Codex, Copilot, Cursor, OpenCode, and 40+ tools).

### Skill Types

| Type | Description |
|---|---|
| **Instruction** | Markdown-only (`SKILL.md` body injected into LLM context as instructions) |
| **Executable** | Has a `scripts/` directory with Python scripts invoked via `uv run --script` |

### Skill Tiers

| Tier | Location | Mutable |
|---|---|---|
| **Built-in** | App bundle `Resources/Skills/` | No (disable only) |
| **Personal** | `~/Library/Application Support/fae/skills/` | Yes |
| **Community** | Same as personal (imported from URL) | Yes |

### Directory Structure

Each skill is a directory with a `SKILL.md` entry point:

```
weather-check/
  SKILL.md              # Required: YAML frontmatter + instructions
  scripts/              # Optional: Python scripts
    fetch_weather.py
  references/           # Optional: detailed docs
  assets/               # Optional: static data
```

### SKILL.md Format

```yaml
---
name: weather-check
description: Check weather for a city. Use when user asks about weather, temperature, or forecasts.
metadata:
  author: fae
  version: "1.0"
---

Check weather using the web_search tool:
1. Search for "[city] weather today"
2. Extract temperature, conditions, and forecast
3. Respond conversationally
```

### Progressive Disclosure

The system prompt only includes skill **names and descriptions** (~50-100 tokens each). The full `SKILL.md` body (up to ~5000 tokens) is loaded only when the LLM activates a skill via `activate_skill`. This keeps the base prompt lean while giving Fae access to detailed instructions when needed.

### Skill Tools

| Tool | Risk | Purpose |
|---|---|---|
| `activate_skill` | Low | Load full SKILL.md body into LLM context |
| `run_skill` | Medium | Execute Python script from skill's `scripts/` directory |
| `manage_skill` | High | Create, delete, or list personal skills |

### Built-in Skills

| Skill | Type | Scripts |
|---|---|---|
| `voice-tools` | Executable | `audio_normalize`, `prepare_voice_sample`, `voice_compare`, `voice_quality_check` |

### Creating a Skill

Ask Fae naturally:

> "Fae, create a skill that checks the weather."

Fae will use `manage_skill(action: "create", ...)` to create a new skill directory with `SKILL.md` and optionally a Python script.

### Managing Skills

| Action | How |
|---|---|
| List skills | "What skills do you have?" |
| Activate a skill | Automatic when task matches description, or explicit via `activate_skill` |
| Run a skill script | "Run voice quality check on this file" |
| Create a skill | "Create a skill that does X" |
| Delete a skill | "Remove the weather skill" |

### Multi-Script Skills

Some skills (like `voice-tools`) contain multiple Python scripts. Specify which script to run:

```
run_skill(name: "voice-tools", script: "voice_quality_check", input: "/path/to/audio.wav")
```

### Python Script Format (PEP 723)

Executable skills use PEP 723 inline metadata for dependency management:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["requests", "rich"]
# ///

import requests
from rich import print

# Your skill logic here...
result = requests.get("https://api.example.com/data")
print(result.json())
```

## Integration with Memory

Self-modification integrates with Fae's memory system:

- **Preferences** are captured as `profile` memories with the `preference` tag.
- **Directives** persist independently of memory (markdown file, not in SQLite).
- **Skill proposals** are surfaced by the scheduler when Fae detects patterns in your interests.

## Safety

- Fae never modifies system files or installs software without explicit approval.
- Python skills run in isolated `uv` environments — no global package pollution.
- The `self_config` tool requires approval for directive changes.
- Writing and running Python scripts requires approval when in `full` tool mode.
- Write-path security (`PathPolicy`) blocks writes to dotfiles, system paths, and Fae's own config.
- Per-tool rate limiting prevents runaway tool use.
