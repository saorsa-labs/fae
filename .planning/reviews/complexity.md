# Complexity Review — Phase 6.2 Task 7

**Reviewer:** Complexity Analyst
**Scope:** All changed files

## Findings

### 1. SHOULD FIX — Duplicated match arms in coordinator.rs
As noted by code quality reviewer: the panel visibility match arms appear in two separate code paths in `run_llm_stage`. The duplication is ~14 lines each. Extracting to a helper reduces cognitive load and maintenance burden.

Proposed refactor:
```rust
fn emit_panel_visibility_events(
    cmd: &VoiceCommand,
    runtime_tx: &Option<broadcast::Sender<RuntimeEvent>>,
) {
    match cmd {
        VoiceCommand::ShowConversation | VoiceCommand::HideConversation => {
            if let Some(rt) = runtime_tx {
                let visible = matches!(cmd, VoiceCommand::ShowConversation);
                let _ = rt.send(RuntimeEvent::ConversationVisibility { visible });
            }
        }
        VoiceCommand::ShowCanvas | VoiceCommand::HideCanvas => {
            if let Some(rt) = runtime_tx {
                let visible = matches!(cmd, VoiceCommand::ShowCanvas);
                let _ = rt.send(RuntimeEvent::ConversationCanvasVisibility { visible });
            }
        }
        _ => {}
    }
}
```

### 2. PASS — FaeNativeApp.onAppear wiring block is long but manageable
The `onAppear` block has grown substantially. It remains linear wiring logic (no branching complexity). Each line has a comment. Acceptable complexity.

### 3. PASS — JitPermissionController dispatch is clean
The new switch cases follow the exact same pattern as existing microphone/contacts cases. Cyclomatic complexity increase is minimal and expected.

### 4. PASS — handler.rs request_move complexity unchanged
Two sequential `emit_event` calls are straightforward.

## Verdict
**CONDITIONAL PASS**

| # | Severity | Finding |
|---|----------|---------|
| 1 | SHOULD FIX | Duplicate visibility handling — extract coordinator helper |
