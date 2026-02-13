# Runtime Model Switching — User Guide

Fae can switch between different LLM models mid-conversation using voice commands. This allows you to seamlessly move between cloud models (like Claude or GPT-4) and local models without restarting the application.

## Supported Voice Commands

| Command | Example | What it does |
|---------|---------|--------------|
| **Switch to a model** | "switch to Claude" | Changes to the best available Claude model |
| | "use the local model" | Switches to on-device model (fae-qwen3) |
| | "change to GPT" | Switches to best available OpenAI model |
| | "switch to the flagship model" | Switches to highest-tier available model |
| **List models** | "list models" | Lists all available models and which is active |
| | "show models" | Same as above |
| **Current model** | "what model are you using?" | Tells you the current active model |
| | "which model?" | Same as above |
| **Help** | "help" | Lists all available voice commands |
| | "what can I say?" | Same as above |

## How It Works

### Startup Selection

When Fae starts, it automatically selects the best available model:

1. **Local is always loaded first** — Qwen3 is loaded on startup for immediate use
2. **Api is optional** — If configured, cloud models are available
3. **Tool mode** — Controlled by `tool_mode` setting (read_only or full)

### Runtime Switching

During a conversation, you can switch models at any time:

1. Say a switch command (e.g., "Fae, switch to Claude")
2. Fae interrupts any ongoing response
3. The model switches immediately
4. Fae confirms with "Switching to Claude Opus 4."
5. Conversation continues with the new model

## Model Targeting

When you say "switch to...", Fae understands:

| Target | Matches |
|--------|---------|
| **Provider name** | "Claude" → best Anthropic model, "GPT" → best OpenAI model |
| **Specific model** | "GPT-4o" → exact model name match |
| **Local** | "local", "offline", "on-device", "Qwen" → local Qwen3 model |
| **Best** | "best", "flagship", "top", "most capable" → highest tier available |

## Architecture

### Two Backends

```
┌─────────────────────────────────────────────┐
│         fae_llm Agent Loop                │
│   (our tools, sandbox, security)           │
├─────────────────────────────────────────────┤
│                                             │
│   ┌──────────────┐   ┌──────────────┐       │
│   │   Local     │   │     Api     │       │
│   │  (Qwen3)   │   │ (OpenAI/    │       │
│   │ mistralrs   │   │ Anthropic)  │       │
│   └──────────────┘   └──────────────┘       │
│                                             │
│   SAME tools, SAME agent loop, SAME sandbox   │
└─────────────────────────────────────────────┘
```

### Tool Modes

Control what the LLM can do:

| Mode | Tools | Description |
|------|-------|-------------|
| `read_only` | read | Safe mode - can only read files |
| `full` | read, bash, edit, write | Full agent mode |

## Configuration

Configure in `~/.config/fae/config.toml`:

```toml
[llm]
# Backend: local or api
backend = "local"

# Tool mode: read_only or full
[llm.tool_mode]
mode = "full"

# Local model settings
model_id = "unsloth/Qwen3-4B-Instruct-2507-GGUF"
context_size_tokens = 32768

# API settings (when backend = "api")
# api_url = "https://api.openai.com/v1"
# api_key = "sk-..."
# api_model = "gpt-4o"
```

## Security

The agent loop is sandboxed:

1. **Path validation** — All file operations stay within workspace
2. **No system directories** — Cannot write to /bin, /usr, /etc
3. **Input sanitization** — Shell injection prevented
4. **Tool mode** — Limits available capabilities

## Voice Commands Reference

| You Say | Fae Does |
|---------|-----------|
| "switch to Claude" | Uses Anthropic API |
| "use the local model" | Uses local Qwen3 |
| "list models" | Shows available models |
| "what model are you using?" | Says current model |
| "help" | Lists commands |
