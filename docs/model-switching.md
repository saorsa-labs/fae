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

When Fae starts, it automatically selects the best available model based on:

1. **Tier** — Models are ranked by capability (Claude Opus 4 > GPT-4o > Gemini 2.0 Flash > local Qwen3)
2. **User Priority** — You can override the tier ranking in `~/.pi/agent/models.json` by adding a `priority` field (higher = better)
3. **Interactive Picker** — If multiple top-tier models are available, Fae shows a list and asks you to choose

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
| **Local** | "local", "offline", "on-device", "Qwen" → local fae-qwen3 model |
| **Best** | "best", "flagship", "top", "most capable" → highest tier available |

Examples:
- "switch to Claude" → Finds "anthropic/claude-opus-4"
- "use GPT-4o" → Finds "openai/gpt-4o"
- "switch to the local model" → Finds "fae-local/fae-qwen3"

## Priority Override

By default, models are ranked by tier. To prefer a specific model, edit `~/.pi/agent/models.json`:

```json
{
  "providers": {
    "openai": {
      "models": [
        {
          "model": "gpt-4o",
          "priority": 100
        }
      ]
    },
    "anthropic": {
      "models": [
        {
          "model": "claude-opus-4",
          "priority": 50
        }
      ]
    }
  }
}
```

Higher `priority` values are preferred. In this example, GPT-4o will be selected at startup even though Claude Opus 4 is higher tier.

## Fallback Behavior

If you request a model that isn't available:

1. Fae says "I couldn't find a model matching {target}."
2. Fae automatically falls back to the next best available model
3. Fae continues the conversation without interruption

This ensures you never lose your conversation state, even if a cloud provider is temporarily unreachable.

## GUI Indicator

When a model is active, the GUI topbar shows a subtle indicator:

```
🤖 anthropic/claude-opus-4
```

This updates in real-time when you switch models, so you always know which model you're talking to.

## Troubleshooting

### "Voice model switching is only available with the Pi backend"

**Cause:** You're using `saorsa-ai` LLM backend instead of Pi.

**Fix:** Edit `~/.config/fae/config.toml`:

```toml
[llm]
backend = "pi"  # Change from "saorsa-ai" to "pi"
```

### Model not found

**Cause:** The requested model isn't configured in `~/.pi/agent/models.json`.

**Fix:**
1. Open `~/.pi/agent/models.json`
2. Ensure the provider has an API key configured
3. Check the model name is spelled correctly
4. Run "list models" to see what's available

### Switch doesn't happen

**Cause:** Model switch interrupted by an error (network issue, API key invalid).

**Fix:** Fae will automatically fall back to the previous working model. Check logs for details:

```bash
RUST_LOG=info,fae=debug fae
```

### "I don't have any models configured"

**Cause:** No models are available (no API keys set, local model not downloaded).

**Fix:**
1. Add API keys to `~/.pi/agent/models.json`:
   ```json
   {
     "providers": {
       "anthropic": {
         "api_key": "sk-ant-..."
       }
     }
   }
   ```
2. Or use the local model (downloads automatically on first use)

## Tips

- **Wake word optional:** "Fae, switch to Claude" and "switch to Claude" both work
- **Case insensitive:** "SWITCH TO CLAUDE" works the same as "switch to claude"
- **Partial names work:** "switch to opus" finds "claude-opus-4"
- **Instant interruption:** Voice commands interrupt ongoing responses immediately
- **No state loss:** Conversation context is preserved across model switches
- **Visual confirmation:** Check the topbar indicator to confirm the switch

## Examples

**Start with auto-selection:**
```
Fae (startup) → Selects "anthropic/claude-opus-4" (highest tier)
```

**Switch to local for privacy:**
```
You: "Fae, switch to the local model"
Fae: "Switching to fae-qwen3."
```

**Try a different provider:**
```
You: "use GPT"
Fae: "Switching to gpt-4o."
```

**Check what's available:**
```
You: "list models"
Fae: "I have access to claude-opus-4, gpt-4o, gemini-2.5-flash, fae-qwen3. Currently using claude-opus-4."
```

**Get help:**
```
You: "what can I say?"
Fae: "You can say: switch to Claude, use the local model, list models, or what model are you using."
```

## See Also

- [Architecture Documentation](architecture/model-selection.md) — How model selection works internally
- [Pi Configuration](../README.md#pi-backend) — Setting up the Pi LLM backend
- [Tier List](architecture/model-selection.md#tier-registry) — Full model capability rankings
