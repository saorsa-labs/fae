# Deferred Tool Execution (Non-Blocking Read-Only Jobs)

Status: Active (Swift runtime)

Fae can execute certain read-only tool calls in the background so the active voice interaction stays responsive.

## What this does

When a request is a safe read-only lookup (for example calendar/notes/mail/contacts), Fae can:

1. acknowledge immediately ("I’ll check that in the background and report back...")
2. show a subtle conversation-header indicator while background lookup is in flight
3. run tool calls asynchronously
4. inject tool results back into conversation state
5. deliver a grounded follow-up response when results are ready

## Eligible tools/actions

Deferred execution is allowlisted and action-gated:

- `calendar`: `list_today`, `list_week`, `list_date`, `search`
- `reminders`: `list_incomplete`, `search`
- `contacts`: `search`, `get_phone`, `get_email`
- `mail`: `check_inbox`, `read_recent`
- `notes`: `search`, `list_recent`
- `web_search`, `fetch_url`, `read`, `scheduler_list`

Non-read actions are excluded.

## Safety guarantees

Deferred mode does **not** create a weaker path:

- broker decisioning still applies
- approval requirements are still enforced
- owner voice gating still applies
- owner-enrollment requirement still applies when configured
- tool failures are surfaced explicitly

If required tool execution does not happen, Fae must say so plainly and must not fabricate a result.

## Approval UX during deferred-capable flows

If approval is required at any point, Fae asks explicitly for yes/no and the overlay shows Yes/No buttons.

While approval is pending, non-answer speech is ignored as a command response; Fae asks again for a clear yes/no.

## Operational notes

- Deferred jobs are tracked in-memory for the current runtime session.
- Jobs are cancelled on pipeline stop/reset.
- Follow-up responses are generated after tool completion and spoken back into the main conversation stream.

## Code anchors

- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
- `native/macos/Fae/Sources/Fae/Agent/ApprovalManager.swift`
