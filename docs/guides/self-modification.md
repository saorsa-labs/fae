# Self-Modification Guide

Fae can modify her own behavior, communication style, and capabilities at your request. Changes persist across conversations.

## Personality Tuning (SelfConfigTool)

The `self_config` tool lets Fae save personality preferences that apply to every future interaction.

### How It Works

When you say something like "be more cheerful" or "always greet me by name", Fae uses the `self_config` tool to persist that preference. The preferences are stored as plain text at:

```
~/Library/Application Support/fae/custom_instructions.txt
```

This file is loaded on every prompt assembly, so changes take effect immediately on the next response.

### Actions

| Action | Description |
|---|---|
| `get_instructions` | Read current custom instructions |
| `set_instructions` | Replace all instructions with new text |
| `append_instructions` | Add a new instruction without removing existing ones |
| `clear_instructions` | Remove all custom instructions, revert to defaults |

### Examples

**Setting a communication style:**
> "Fae, be more concise in your responses."

Fae calls `self_config(action: "append_instructions", value: "Be more concise — keep responses to 1-2 sentences unless the topic requires more detail.")`.

**Overriding all preferences:**
> "Fae, forget all my style preferences and start fresh."

Fae calls `self_config(action: "clear_instructions")`.

**Checking current preferences:**
> "Fae, what are my current style preferences?"

Fae calls `self_config(action: "get_instructions")` and reads back the result.

## Python Skills

Fae can write, install, and run Python scripts to extend her capabilities. Skills use `uv` (an ultra-fast Python package manager) for dependency management.

### How Skills Work

1. Fae writes a Python script to `~/Library/Application Support/fae/skills/`.
2. The script uses PEP 723 inline metadata to declare dependencies.
3. Fae runs it via `uv run --script` which auto-installs dependencies in an isolated environment.

### PEP 723 Inline Metadata

Each skill declares its dependencies inline, so no separate `requirements.txt` is needed:

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

### Creating a Skill

Ask Fae naturally:

> "Fae, write me a skill that checks the weather."

Fae will:
1. Write a Python script with PEP 723 metadata to `~/Library/Application Support/fae/skills/weather.py`
2. Test it with `uv run --script weather.py`
3. Report the result

### Managing Skills

| Action | How |
|---|---|
| List skills | "What skills do you have?" |
| Run a skill | "Run the weather skill" |
| Edit a skill | "Update the weather skill to include humidity" |
| Delete a skill | "Remove the weather skill" |
| View source | "Show me the code for the weather skill" |

### Skill Directory

```
~/Library/Application Support/fae/skills/
├── weather.py          # Weather checking skill
├── stock_tracker.py    # Stock price monitoring
└── news_digest.py      # Daily news summary
```

## Integration with Memory

Self-modification integrates with Fae's memory system:

- **Preferences** are captured as `profile` memories with the `preference` tag.
- **Custom instructions** persist independently of memory (plain text file, not in SQLite).
- **Skill proposals** are surfaced by the scheduler when Fae detects patterns in your interests.

## Safety

- Fae never modifies system files or installs software without explicit approval.
- Python skills run in isolated `uv` environments — no global package pollution.
- The `self_config` tool does not require approval (it only modifies Fae's own behavior).
- Writing and running Python scripts requires approval when in `full` tool mode.
