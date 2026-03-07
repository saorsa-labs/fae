# Python Integration Architecture

Fae uses Python as an **extension mechanism** rather than a core runtime. The Swift app is the primary codebase, with Python subprocesses handling specific ML workloads and extensible skills.

## Design Philosophy

```
┌─────────────────────────────────────────────────────────┐
│  Swift App (FaeApp)                                     │
│  ├── UI (SwiftUI, Metal shaders for orb)               │
│  ├── System integration (AppleScript, notifications)   │
│  ├── Memory (SQLite, MemoryOrchestrator)               │
│  ├── Tools (ToolRegistry - native Swift tools)         │
│  └── Pipeline (PipelineCoordinator)                    │
│       ├── STT: MLXSTTEngine (Swift/MLX - Apple Silicon) │
│       ├── LLM: MLXLLMEngine (Swift/MLX - Apple Silicon) │
│       └── TTS: KokoroPythonTTSEngine (subprocess)      │
├─────────────────────────────────────────────────────────┤
│  Python Subprocesses (via uv)                          │
│  ├── kokoro_tts_server.py (Kokoro-ONNX TTS)            │
│  └── Skills with scripts/ directories                  │
└─────────────────────────────────────────────────────────┘
```

**Why this split?**

| Component | Runtime | Reason |
|-----------|---------|--------|
| LLM | Swift/MLX | Metal GPU acceleration on Apple Silicon |
| STT | Swift/MLX | Low latency, GPU acceleration |
| TTS | Python/ONNX | CPU-based, avoids Metal contention with LLM |
| Skills | Python | Hot-reloadable, user-extensible, ecosystem access |

## uv: The Python Runtime Manager

Fae uses [uv](https://docs.astral.sh/uv/) exclusively for Python dependency management. We chose uv because:

1. **Zero-config environments** - PEP 723 inline script metadata means scripts declare their own dependencies
2. **Isolated by default** - Each script gets its own cached environment
3. **Fast** - 10-100x faster than pip for installs
4. **Single binary** - Easy to bundle with the app

### uv Location Strategy

Fae looks for uv in this order:

1. **User install**: `~/.local/bin/uv` (standard location after auto-install)
2. **Homebrew**: `/opt/homebrew/bin/uv`
3. **System**: `/usr/local/bin/uv`
4. **PATH fallback**: `uv` (via `/usr/bin/env`)

### Automatic Installation

**Fae takes care of her users.** When Python features are first needed (TTS, skills with scripts), Fae will:

1. Check if uv is installed
2. If not, show a friendly approval dialog
3. If approved, install uv automatically (no terminal required!)
4. Continue with the original operation

```
┌─────────────────────────────────────────────────────┐
│          Install uv (Python package manager)?       │
├─────────────────────────────────────────────────────┤
│ uv is needed for voice synthesis and Python-based  │
│ skills. It's a fast, safe package manager from     │
│ Astral.                                            │
│                                                    │
│ Fae will download and install it automatically.    │
│ This is a one-time setup.                          │
│                                                    │
│     [Install]    [Not Now]    [Learn More]         │
└─────────────────────────────────────────────────────┘
```

**No command line typing required.** Fae handles everything.

### Implementation

The auto-install is managed by two components:

- **`DependencyInstaller`** (`Runtime/DependencyInstaller.swift`): Handles approval dialogs and installation for any required tool
- **`UVRuntime.ensureAvailable()`**: The preferred method for code that needs uv - checks, prompts, installs if needed

## Script Architecture

### PEP 723 Inline Metadata

All Fae Python scripts use [PEP 723](https://peps.python.org/pep-0723/) inline script metadata:

```python
#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "kokoro-onnx",
#   "numpy",
#   "onnxruntime",
# ]
# ///
```

This allows `uv run --script script.py` to:
1. Create an isolated virtual environment (cached)
2. Install exactly the declared dependencies
3. Run the script

### Script Locations

| Location | Purpose |
|----------|---------|
| `Fae.app/.../Resources/Scripts/` | Core scripts (TTS server) |
| `Fae.app/.../Resources/Skills/*/scripts/` | Built-in skill scripts |
| `~/.fae/skills/*/scripts/` | User-installed skills |

## TTS Integration: KokoroPythonTTSEngine

The TTS engine runs Kokoro-ONNX in a persistent subprocess:

```
Swift (KokoroPythonTTSEngine)
    │
    │ spawn on first synthesis
    ▼
Python subprocess (kokoro_tts_server.py)
    │
    ├── stdin: JSON requests {"text": "...", "voice": "af_heart", "speed": 1.0}
    │
    └── stdout: Binary PCM chunks [4-byte length][float32 samples]...
                Sentinel [length=0] marks end of utterance
                Error [length=-1][error message] on failure
```

**Why subprocess instead of in-process?**

- **Metal contention**: MLX (LLM) and ONNX both want GPU. Running TTS on CPU via subprocess eliminates stuttering.
- **Crash isolation**: Python crash doesn't take down the app
- **Hot update**: Can update TTS model without rebuilding app

### Process Lifecycle

1. **Lazy spawn**: Server starts on first `synthesize()` call
2. **Stay warm**: Process persists across utterances (model loaded once)
3. **Graceful shutdown**: Terminated on app exit or TTS engine shutdown
4. **Crash recovery**: Auto-respawn on next request if process dies

## Skill Python Scripts

Skills can include Python scripts in their `scripts/` directory:

```
my-skill/
├── SKILL.md           # Skill manifest
├── scripts/
│   ├── action.py      # Main action script
│   └── helper.py      # Helper module
└── config.json        # Optional config
```

### Script Execution (SafeSkillExecutor)

```swift
// Runs script in sandbox with timeout
exec /usr/bin/env uv run --script /path/to/script.py
```

Scripts receive:
- **stdin**: JSON input from the skill invocation
- **stdout**: JSON response back to Fae
- **stderr**: Logged for debugging

### Security Constraints

- Scripts run with the user's privileges (not root)
- No network access by default (configurable per-skill)
- Timeout enforced (default 30s)
- Approval required for first-run of untrusted skills

## Environment Isolation

### Cache Locations

| Cache | Location | Purpose |
|-------|----------|---------|
| uv environments | `~/.cache/uv/` | Per-script venvs |
| HuggingFace models | `~/.cache/huggingface/hub/` | Shared model cache |
| Fae app data | `~/Library/Application Support/fae/` | Config, memory, logs |

### Why Not Bundle a Full venv?

1. **Size**: A bundled venv with all dependencies would add 500MB+ to app size
2. **Updates**: Can't update Python packages without app rebuild
3. **Architecture**: Would need separate arm64/x86_64 builds

Instead, uv creates cached environments on-demand. First run downloads dependencies (~30s for TTS), subsequent runs reuse the cache (<1s).

## Debugging Python Issues

### Check uv Status

```bash
# Is uv installed?
which uv
uv --version

# Where are cached environments?
ls ~/.cache/uv/

# Run script manually
cd /path/to/Fae.app/Contents/Resources/Scripts
uv run --script kokoro_tts_server.py
```

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| uv install prompt keeps appearing | User declined, then needed again | Go to Settings → Developer → Reset declined dependencies |
| TTS timeout on first run | Downloading dependencies | Wait ~30s, check network |
| "Model not found" | HuggingFace cache missing | Fae will download automatically on first TTS use |
| Script crashes | Dependency conflict | Clear cache: `rm -rf ~/.cache/uv/` |

### Logs

- TTS server logs go to stderr, visible in Xcode console or `Console.app`
- Skill script logs: `~/Library/Application Support/fae/logs/skills/`

## Design Decision: Auto-Install vs Bundling

We chose **automatic installation** over bundling uv in the app:

| Approach | Pros | Cons |
|----------|------|------|
| **Auto-install** ✓ | Always latest version, smaller app, Fae can update independently | Requires network on first use |
| Bundling | Works offline, guaranteed version | +15MB app size, stale versions, update requires app release |

**Fae takes care of her users.** When uv is needed, she asks permission once and handles installation. This keeps the app small and ensures users always have the latest, most secure version.

## Adding New Python Scripts

### For Core Features

1. Create script in `Sources/Fae/Resources/Scripts/`
2. Add PEP 723 metadata header
3. Register in Xcode project (Copy Bundle Resources)
4. Create Swift actor to manage subprocess

### For Skills

1. Create `scripts/` directory in skill folder
2. Add script with PEP 723 metadata
3. Reference in SKILL.md manifest

Example skill script:

```python
#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests"]
# ///
"""Fetch weather data for a location."""

import json
import sys
import requests

def main():
    req = json.load(sys.stdin)
    location = req.get("location", "Edinburgh")
    
    # ... fetch weather ...
    
    result = {"temperature": 12, "condition": "cloudy"}
    json.dump(result, sys.stdout)

if __name__ == "__main__":
    main()
```

## References

- [uv documentation](https://docs.astral.sh/uv/)
- [PEP 723 – Inline script metadata](https://peps.python.org/pep-0723/)
- [Kokoro ONNX](https://github.com/onnx-community/Kokoro-82M-v1.0-ONNX)
- ADR-003: Local LLM Inference (`docs/adr/003-local-llm-inference.md`)
