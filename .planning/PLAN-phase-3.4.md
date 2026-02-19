# Phase 3.4: JIT Permission Flow

## Overview

Enable just-in-time (JIT) permission requests mid-conversation. When the LLM attempts
to use an Apple ecosystem tool that requires a permission not yet granted, the system
should request that permission, wait for user grant/deny, then resume the LLM turn.

The key missing pieces are:

1. `AvailabilityGatedTool` uses a frozen snapshot `Arc<PermissionStore>` — it never
   sees runtime grants. Needs `Arc<Mutex<PermissionStore>>` or a live shared store.
2. The `build_registry()` function creates its own isolated `PermissionStore` — not
   connected to the `FaeDeviceTransferHandler`'s config.
3. No mechanism for `AvailabilityGatedTool` to emit a JIT capability request to Swift
   and block waiting for the response.
4. No dynamic tool registration / deregistration at runtime.
5. No test covering the full JIT flow.

Architecture follow existing patterns:
- `PermissionStore` lives in `SpeechConfig` (persisted to `config.toml`)
- `FaeDeviceTransferHandler` owns the config, grants/denies permissions
- `AvailabilityGatedTool` wraps each Apple tool
- `capability.requested` event already has `jit` field

---

## Task 1: SharedPermissionStore — live Arc<Mutex<PermissionStore>>

**Files:**
- `src/permissions.rs` (extend)

**Description:**
Add `SharedPermissionStore` type alias: `pub type SharedPermissionStore = Arc<Mutex<PermissionStore>>`.
Add `PermissionStore::into_shared(self) -> SharedPermissionStore` convenience method.
Add `PermissionStore::default_shared() -> SharedPermissionStore`.
The `Mutex` is `std::sync::Mutex` (matching existing codebase style).
Add 4 unit tests:
1. `shared_store_reflects_runtime_grant` — clone the Arc, grant in one clone, check in another
2. `shared_store_reflects_runtime_deny`
3. `default_shared_starts_empty`
4. `into_shared_preserves_existing_grants`

---

## Task 2: Update AvailabilityGatedTool to use SharedPermissionStore

**Files:**
- `src/fae_llm/tools/apple/availability_gate.rs` (modify)

**Description:**
Change `permissions: Arc<PermissionStore>` field to `permissions: SharedPermissionStore`.
Update `AvailabilityGatedTool::new()` to accept `SharedPermissionStore`.
In `execute()`, lock the mutex to check `is_granted()`.
Update all existing unit tests (they use `Arc::new(store)` — change to
`store.into_shared()` or `Arc::new(Mutex::new(store))`).
Add doc comment explaining the live-view semantics.

---

## Task 3: Thread SharedPermissionStore through FaeDeviceTransferHandler

**Files:**
- `src/host/handler.rs` (extend)

**Description:**
Add `shared_permissions: SharedPermissionStore` field to `FaeDeviceTransferHandler`.
In `new()`, construct it from `config.permissions.clone().into_shared()`.
In `grant_capability()`: after updating the in-memory config, also update
`shared_permissions` (lock, call `grant(kind)`).
In `deny_capability()`: after updating in-memory config, also update
`shared_permissions` (lock, call `deny(kind)`).
Add accessor `pub fn shared_permissions(&self) -> SharedPermissionStore`.
Add 3 unit tests:
1. `shared_permissions_reflects_grant_capability` — call `grant_capability`, verify
   `shared_permissions` is_granted returns true.
2. `shared_permissions_reflects_deny_capability`
3. `shared_permissions_is_consistent_with_config` — grant, then check both config and
   shared_permissions agree.

---

## Task 4: Wire SharedPermissionStore through build_registry()

**Files:**
- `src/agent/mod.rs` (modify)

**Description:**
Change `build_registry()` signature to accept `shared_permissions: SharedPermissionStore`.
Remove the local `Arc::new(PermissionStore::default())` created inside `build_registry`.
Update the `gated!` macro to pass `Arc::clone(&shared_permissions)`.
Update `FaeAgentLlm::new()` to accept `shared_permissions: SharedPermissionStore` and
pass it to `build_registry()`.
Update `PipelineCoordinator` (or wherever `FaeAgentLlm::new()` is called) to thread
the shared permissions from the handler.
Add note in doc comment on `build_registry` explaining this is the live store from the
handler that updates at runtime.

---

## Task 5: JIT capability.request event enriched with tool_name + tool_action

**Files:**
- `src/host/channel.rs` (modify — parse_capability_request)
- `src/host/handler.rs` (modify — request_capability emits enriched event)

**Description:**
Extend `CapabilityRequestPayload` to include optional `tool_name: Option<String>` and
`tool_action: Option<String>` fields (what the LLM was trying to do when it requested
the permission).
Update `parse_capability_request()` to extract these from the payload.
Update `handle_capability_request()` to include them in the `capability.requested` event
payload:
```json
{
  "capability": "contacts",
  "reason": "I need to look up Alice's email",
  "jit": true,
  "tool_name": "search_contacts",
  "tool_action": "search contacts for Alice"
}
```
Update `FaeDeviceTransferHandler::request_capability()` to log the enriched context.
Add 3 unit tests in `channel.rs` tests:
1. `capability_request_with_jit_fields_parsed` — verify tool_name/action are extracted
2. `capability_request_without_jit_fields_defaults_to_none`
3. `capability_request_event_includes_jit_fields`

---

## Task 6: Emit permissions_changed event on grant/deny for UI display

**Files:**
- `src/host/handler.rs` (modify grant_capability and deny_capability)

**Description:**
After persisting a grant or deny, emit a `permissions.changed` event via `emit_event()`:
```json
{
  "event": "permissions.changed",
  "payload": {
    "kind": "contacts",
    "granted": true,
    "all_granted": ["microphone", "contacts"]
  }
}
```
This allows the conversation UI (Task 7 of ROADMAP says "Show granted permissions in
conversation UI") to update in real-time without polling.
Add 4 unit tests in `handler.rs` tests section using `temp_handler_with_events()`:
1. `grant_emits_permissions_changed_event`
2. `deny_emits_permissions_changed_event`
3. `permissions_changed_event_includes_correct_kind`
4. `permissions_changed_event_includes_all_granted`

---

## Task 7: JIT permission flow integration — AvailabilityGatedTool emits JIT request

**Files:**
- `src/fae_llm/tools/apple/availability_gate.rs` (extend)

**Description:**
Add optional `jit_request_tx: Option<mpsc::UnboundedSender<JitPermissionRequest>>` field
to `AvailabilityGatedTool`.

Define `JitPermissionRequest` struct in `src/permissions.rs`:
```rust
pub struct JitPermissionRequest {
    pub kind: PermissionKind,
    pub tool_name: String,
    pub reason: String,
    pub respond_to: oneshot::Sender<bool>,
}
```

When permission is not granted AND `jit_request_tx` is set:
1. Send `JitPermissionRequest` to the channel
2. Block (spin-loop with 25ms sleep) waiting for the oneshot response, up to 60s
3. If granted (response = true): re-check permission store, proceed with execution
4. If denied (response = false): return graceful failure message

Add `AvailabilityGatedTool::with_jit_channel()` builder method.
Add unit tests:
1. `jit_grant_allows_execution` — mock JIT responder grants; verify tool executes
2. `jit_deny_returns_graceful_failure`
3. `jit_timeout_returns_graceful_failure`
4. `no_jit_channel_returns_immediate_failure` (existing behavior preserved)

---

## Task 8: End-to-end test — JIT permission flow from capability.request to tool execution

**Files:**
- `tests/jit_permission_flow.rs` (new)

**Description:**
Integration tests covering the full JIT permission flow using
`FaeDeviceTransferHandler` + `HostCommandServer`:

1. `jit_capability_request_emits_event_with_jit_flag` — send `capability.request`
   with `jit: true`, verify `capability.requested` event has correct payload
2. `jit_grant_via_capability_grant_persists_to_shared_store` — request then grant,
   verify `SharedPermissionStore` reflects the grant
3. `jit_deny_via_capability_deny_persists_to_shared_store` — request then deny,
   verify `SharedPermissionStore` reflects the deny
4. `permissions_changed_event_emitted_on_jit_grant` — grant via JIT, verify
   `permissions.changed` event is emitted
5. `permissions_changed_event_emitted_on_jit_deny`
6. `capability_request_with_tool_context_preserved_in_event` — send request with
   `tool_name` and `tool_action`, verify they appear in the emitted event
7. `shared_permission_store_live_view_reflects_runtime_grant` — verify that two
   `AvailabilityGatedTool` instances sharing the same `SharedPermissionStore` both
   see a grant made to one of them
8. `revocation_via_deny_blocks_previously_allowed_tool` — grant, verify tool passes
   gate, then deny, verify tool is blocked again

---

## Summary

8 tasks: SharedPermissionStore type, AvailabilityGatedTool update, thread through handler,
wire through build_registry, enrich JIT events, permissions_changed emission, JIT blocking
flow in gate tool, end-to-end integration tests.
