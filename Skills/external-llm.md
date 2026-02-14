# External LLM

Use this skill when the user asks to add, update, switch, or test external (remote API) LLM providers.

## Security Rules

- Keep secret handling local. Never send API keys/tokens to third-party tools/services while configuring.
- Never store plain API keys in skill files.
- Prefer secret references in profile files:
  - environment variable (`type = "env"`)
  - local command (`type = "command"`) for keychain/secret manager lookup
- Use plain `literal` secrets only if the user explicitly requests it and understands the risk.
- Do not print full secrets in responses. Redact all but a short prefix/suffix when needed.

## Storage Contract

- External profile files: `~/.fae/external_apis/<profile>.toml`
- Active profile selector: `~/.config/fae/config.toml` under `[llm] external_profile = "<profile>"`
- Do not rely on GUI settings menus for this flow.

Because `read/write/edit` tools are workspace-scoped, use `bash` for `~/.fae` and `~/.config/fae` paths.

## Profile Schema

```toml
provider = "openai" # hint: openai, anthropic, deepseek, ollama, vllm, etc.
api_type = "openai_completions" # openai_completions | openai_responses | anthropic_messages
api_url = "https://api.openai.com"
api_model = "gpt-4o-mini"
enabled = true
api_version = "2023-06-01" # optional, mainly for anthropic
api_organization = "org_..." # optional, OpenAI-compatible providers

[api_key]
type = "env" # none | env | command | literal
var = "OPENAI_API_KEY"
```

Command-based key example (macOS keychain):

```toml
[api_key]
type = "command"
cmd = "security find-generic-password -w -s 'fae-openai' -a '$USER'"
```

## Setup Workflow

1. Confirm target provider details with the user:
   - profile name
   - provider hint
   - API type
   - base URL
   - model ID
   - secret reference method (`env` or `command` preferred)
2. Create `~/.fae/external_apis/` if missing.
3. Write/update `~/.fae/external_apis/<profile>.toml`.
4. Update `~/.config/fae/config.toml`:
   - `[llm]`
   - `backend = "api"` or `backend = "agent"` (for auto local fallback behavior)
   - `external_profile = "<profile>"`
   - keep `enable_local_fallback = true` unless user asks otherwise.
5. Preserve existing non-LLM settings.

## Provider Mapping Guidance

- `api_type = "anthropic_messages"` for Anthropic Messages API.
- `api_type = "openai_responses"` for providers requiring Responses API semantics.
- `api_type = "openai_completions"` for OpenAI-compatible chat/completions APIs (OpenAI-compatible local servers included).

If unsure, detect from docs/examples and set the most specific type.

## Required Testing (Run After Setup)

Run at least one endpoint-level test and one Fae-level test.

Endpoint test examples:

- OpenAI-compatible:
```bash
curl -sS "${BASE_URL%/}/v1/models" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json"
```

- Anthropic:
```bash
curl -sS "${BASE_URL%/}/v1/messages" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"MODEL","max_tokens":32,"messages":[{"role":"user","content":"ping"}]}'
```

Fae-level validation:

- Confirm config contains the expected `external_profile`.
- Trigger a short response generation through Fae and verify it completes without provider/auth errors.
- Report selected provider/model back to the user.

## Troubleshooting Policy

When setup or tests fail:

1. Inspect HTTP status and error payload first.
2. Re-check URL/model/api_type/header requirements.
3. Re-check secret resolution (`env` present, command output non-empty).
4. If still unresolved, use web search to verify current provider docs and required request shape.
5. Apply fix, retest, and summarize root cause + final state.

Common fixes:

- `401/403`: key invalid, wrong auth header, missing org/project header.
- `404`: wrong base URL path or model ID.
- `429`: rate limits/quotas.
- `400`: wrong API type or payload format.

## Response Format To User

After completion, always return:

- profile name
- provider + api_type
- base URL + model
- secret method used (`env`/`command`/`literal`/`none`, never full secret)
- exact tests run and pass/fail
- any remaining manual follow-up
