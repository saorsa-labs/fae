# Manual QA + Debug Console Checklist (Voice-in → Voice-out)

Use this checklist when validating Fae end-to-end behavior. Keep the Debug Console open and verify each expected marker.

## 0) Pre-flight

1. Open **Debug Console** from menu.
2. Click **Clear**.
3. Ensure pipeline starts cleanly.

Expected debug markers:

- `QA: Pipeline start requested`
- `QA: Pipeline running mode=... toolMode=...`
- `QA: Degraded mode -> full (context=startup)` (or explicit degraded state)
- `QA: Setup audit: active_profile_names=[...]`

---

## 1) Voice understanding + command parsing

Say:

- "show canvas"
- "open settings"
- "show tools and permissions"

Expected markers per utterance:

- `STT: ...`
- `Command: Parsed voice command: ...`
- `Command: Evaluate command: ...`
- `Command: Handled voice command in ...ms`

---

## 2) Governance transaction safety

### 2a. Low-risk setting (no confirmation)

Say: "enable thinking mode"

Expect:

- `Govern: Accepted governance command ...`
- `Govern: Apply setting via voice: llm.thinking_enabled=true`
- `Govern: Apply governance action=set_setting ...`
- `Command: Dispatch config.patch payload=key=llm.thinking_enabled,...`

### 2b. High-risk setting (confirmation)

Say: "unlock your voice" (turns lock off)

Expect:

- `Approve: Queued confirmation for high-risk setting: tts.voice_identity_lock=false`
- On "yes":
  - `Approve: Governance confirmation decision=true action=set_setting`
  - `Govern: Apply governance action=set_setting ...`
- On "no":
  - `Approve: Governance confirmation decision=false ...`

### 2c. Tool mode high-risk

Say: "set tool mode to full no approval"

Expect:

- confirmation prompt markers (`Approve`)
- governance apply marker only after explicit approval

---

## 3) Permission flow (voice or canvas)

Say: "request camera permission"

Expect:

- `Govern: Permission request via voice: camera`
- `Govern: Apply governance action=request_permission ...`
- `Govern: Inbound action=request_permission source=...`
- `Govern: Refreshing permissions snapshot after request: camera`

---

## 4) Normal model reaction (no tools)

Ask a conversational question.

Expect:

- `QA: === TURN START user=... ===`
- `Pipeline: LLM generating ...`
- `LLM:` and/or `Think:` token stream
- `QA: Model raw response preview: ...`
- `Pipeline: TTS: ...`
- `QA: === TURN END spoken_chars=... tool_calls=0 ===`

---

## 5) Tool-backed question

Ask a question that should use tools (web/search/file/etc).

Expect:

- `Pipeline: Found N tool call(s): ...`
- `Tool→ id=... name=... args=...`
- `Approve: Broker decision for ...`
- `Tool← id=... name=... status=... output=...`
- `QA: Tool execution summary: success=... failure=...`

If blocked/hidden:

- `Pipeline: ⚠️ Tools HIDDEN from LLM: ...`
- `QA: Building blocked-tools remediation card reason=...`

---

## 6) Reliability / safety edge checks

- Interrupt while speaking (barge-in)
  - expect `Command: Barge-in triggered rms=...`
- Trigger ambiguous approval response
  - expect `Approve: Ambiguous ... response`
- Confirm no parse regressions
  - if `<tool_call>` appears but no parsed call:
    - expect `QA: ⚠️ Model emitted tool_call markup but no valid calls parsed`

---

## 7) Post-run evidence capture

1. In Debug Console: **Copy All**.
2. Save as QA artifact.
3. Include:
   - command latency traces,
   - governance apply traces,
   - tool decision traces,
   - degraded mode line,
   - setup audit lines.
