---
name: external-llm
description: Configure external LLM providers (OpenAI, Anthropic, OpenAI-compatible, etc.) so Fae can delegate tasks to remote agents.
metadata:
  author: fae
  version: "1.0"
---

Use this skill when the user asks to add, update, switch, or test an external LLM provider for their Fae setup.

## Security Rules

- **Never send API keys to third-party services** during configuration.
- **Never store plain API keys** in skill files or config.
- Prefer secret references:
  - `type = "env"` — read from environment variable
  - `type = "command"` — fetch from macOS Keychain via `security find-generic-password`
- Only use `type = "literal"` if the user explicitly understands the risk.
- Never echo full secrets in conversation — show only prefix/suffix (e.g. `sk-proj-...x7f2`).

## Storage Contract

| What | Where |
|------|-------|
| Provider profiles | `~/.fae/external_apis/<name>.toml` |
| Active profile selector | `~/.config/fae/config.toml` under `[llm]` |

Because `read`/`write`/`edit` tools are workspace-scoped, use `bash` for these paths.

## Profile Schema

```toml
provider = "openai"  # openai | anthropic | deepseek | openai_compatible | ...
api_type = "openai_completions"   # openai_completions | openai_responses | anthropic_messages
api_url = "https://api.openai.com/v1"
api_model = "gpt-4o-mini"
enabled = true
api_version = "2023-06-01"   # optional, mainly for Anthropic

[api_key]
type = "env"   # none | env | command | literal
var = "OPENAI_API_KEY"   # for type = "env"
```

Keychain command (macOS):
```toml
[api_key]
type = "command"
cmd = "security find-generic-password -w -s 'fae-openai' -a '$USER'"
```

## Setup Workflow

1. Confirm details with the user: profile name, provider, API type, base URL, model, secret method.
2. Create `~/.fae/external_apis/` if missing.
3. Write `~/.fae/external_apis/<name>.toml`.
4. Update `~/.config/fae/config.toml`:
   ```toml
   [llm]
   backend = "api"
   external_profile = "<name>"
   enable_local_fallback = true
   ```
5. Run an endpoint test (see below).
6. Report back: profile name, provider + API type, model, secret method, test result.

## API Type Guidance

| Provider | API type |
|---------|----------|
| OpenAI, DeepSeek, OpenAI-compatible local servers | `openai_completions` |
| Providers requiring Responses API semantics | `openai_responses` |
| Anthropic | `anthropic_messages` |

If unsure, check the provider's API documentation and use the most specific type available.

## Required Testing

Always verify after setup:

**OpenAI-compatible:**
```bash
curl -sS "${BASE_URL%/}/v1/models" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json"
```

**Anthropic:**
```bash
curl -sS "${BASE_URL%/}/v1/messages" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"MODEL","max_tokens":32,"messages":[{"role":"user","content":"ping"}]}'
```

Then trigger a short Fae generation to confirm end-to-end success.

## After Setup — Report To User

Always return:
- Profile name and provider + API type
- Base URL and model
- Secret method used (never the secret itself)
- Test results (pass/fail)
- Any remaining manual steps
