# Damage Control Policy

The damage-control layer is Fae's layer-zero safety net — a pre-broker policy that intercepts tool calls and can hard-block them or require deliberate manual confirmation. It runs before `TrustedActionBroker`, before the outbound exfiltration guard, and before any progressive approval logic.

The layer addresses two specific gaps that `TrustedActionBroker` was not designed to cover:

1. **Voice approval bypass** — the normal `.confirm` path accepts voice "yes/no". For truly catastrophic operations, voice is insufficient. A physical button press is the minimum viable safety gate.
2. **Model locality** — when a non-local (API/cloud) model participates via co-work mode, credential dotfiles must be zero-access. Even a trusted local model could be misled into exfiltrating `.ssh` keys to an external service.

---

## Three-tier response model

### Block

Hard deny. No dialog, no overlay, no override. The tool call returns an error immediately.

Used for operations from which there is literally no recovery:

| Pattern | Reason |
|---------|--------|
| `rm -rf /` | Deletes filesystem root |
| `mkfs`, `diskutil erase`, `diskutil zeroDisk` | Disk format |
| `dd of=/dev/<anything except null>` | Raw disk write |
| `chmod -R 000 /` | Strip all permissions from root |

### Disaster Warning

Catastrophic, irreversible operation — but the user might theoretically have a reason. Shows a full-width red-border **DISASTER WARNING** overlay with:
- `exclamationmark.triangle.fill` icon
- Bold "DISASTER WARNING" header in red
- Description of exactly what will be destroyed
- "This operation is IRREVERSIBLE. Voice approval is not accepted."
- **Cancel** (green, safe default) + **Proceed Anyway** (red, right-aligned)
- No timeout, no "Always", no voice

Used when destruction is total but not literally impossible to want:

| Pattern | Reason |
|---------|--------|
| `rm -rf ~/` | Entire home directory |
| `rm -rf ~/Documents` or `~/Desktop` | Major user folder |
| `rm -rf ~/Library` | All app data, preferences, keychains |

### Confirm Manual

Dangerous operation with common legitimate uses. Shows an orange-border **Manual Approval Required** overlay:
- "Manual Approval Required" header in orange
- Description of the operation
- "This operation requires a deliberate button press. Voice approval is not accepted."
- **No** (red) + **Proceed** (orange)
- No timeout, no "Always", no voice

Used for:

| Pattern | Reason |
|---------|--------|
| `sudo rm -rf` | Privileged recursive delete |
| `curl ... \| bash` (or sh/zsh/fish/python) | Curl-pipe-shell |
| `wget ... \| bash` | Wget-pipe-shell |
| `launchctl bootout/disable system/` | Disable system daemon |
| `osascript -e ... System Events` | AppleScript system automation |
| bash `rm`/`mv` on `~/Library/Application Support/fae/` or `~/.fae-vault` | Fae's own data and backup vault |

---

## Dual trust model

### Local model (MLX on-device)

Full read/write access everywhere, subject to normal `TrustedActionBroker` policy. Credential files are accessible because the model runs locally and cannot exfiltrate data without going through Fae's existing outbound exfiltration guard.

### Non-local/co-work API model

The following paths are **zero-access** — reads AND writes are hard-blocked, no dialog:

| Path | What it protects |
|------|-----------------|
| `~/.ssh` | SSH private keys |
| `~/.gnupg` | GPG private keys |
| `~/.aws` | AWS credentials |
| `~/.azure` | Azure credentials |
| `~/.kube` | Kubernetes config |
| `~/.docker/config.json` | Docker registry auth |
| `~/.netrc` | Plaintext credentials |
| `~/.npmrc` | npm auth tokens |

These rules have `nonLocalOnly: true` in the default configuration and are completely inactive when the local MLX model is running.

---

## Why these tiers exist

### The autonomy trade-off

Fae is designed to be highly autonomous — that is the point. The damage-control gates add friction only on operations where friction can save you. Everywhere else, Fae operates without interruption.

The friction surface is intentionally minimal:
- `rm -rf /` is never a good idea from an AI assistant
- `rm -rf ~/` almost certainly isn't either
- `curl <url> | bash` is the pattern that compromises millions of systems every year

For everything else — file writes, bash commands, calendar mutations, email — the normal broker policy handles it, with voice approval available.

### There is no undo for `rm -rf ~/`

The existing `ReversibilityEngine` creates pre-mutation file checkpoints. It cannot help after `rm -rf ~/` completes. The Git Vault at `~/.fae-vault` helps, but only restores what was committed before the deletion. A physical click is the minimum viable gate for operations in this category.

### A trusted model can be misled

Even a local MLX model running entirely on your Mac can be prompted by malicious content (prompt injection via a webpage, document, or calendar event) into making tool calls it wouldn't otherwise make. The damage-control layer is not about distrust of Fae — it is about defense-in-depth for the worst-case misuse paths.

---

## Rollback story

If something goes wrong:

1. **Git Vault** — `~/.fae-vault` contains daily snapshots of all Fae config and memory. Use Help > Rescue Mode > Restore from Vault to pick a snapshot.

2. **ReversibilityEngine** — file mutations on the `write` and `edit` tools create pre-mutation checkpoints in `~/Library/Application Support/fae/recovery/`. These expire after 24 hours but cover recent file changes.

3. **macOS Time Machine** — external to Fae but the standard recovery path for home directory destruction.

4. **Fae config reset** — `~/Library/Application Support/fae/` can be reconstructed from the Git Vault. The vault is protected from bash deletion by a `confirm_manual` rule.

---

## Default rules table

| Category | Pattern/Path | Action | Non-local only |
|----------|-------------|--------|---------------|
| bash | `rm -rf /` | block | no |
| bash | `mkfs`, `diskutil erase` | block | no |
| bash | `dd of=/dev/*` (not null) | block | no |
| bash | `chmod -R 000 /` | block | no |
| bash | `rm -rf ~/` | disaster | no |
| bash | `rm -rf ~/Documents`, `~/Desktop` | disaster | no |
| bash | `rm -rf ~/Library` | disaster | no |
| bash | `sudo rm -rf` | confirm_manual | no |
| bash | `curl \| bash` | confirm_manual | no |
| bash | `wget \| bash` | confirm_manual | no |
| bash | `launchctl bootout/disable system/` | confirm_manual | no |
| bash | `osascript -e ... System Events` | confirm_manual | no |
| bash + path | `rm`/`mv` on `~/Library/Application Support/fae/` | confirm_manual | no |
| bash + path | `rm`/`mv` on `~/.fae-vault` | confirm_manual | no |
| read/write/edit/bash | `~/.ssh` | block | **yes** |
| read/write/edit/bash | `~/.gnupg` | block | **yes** |
| read/write/edit/bash | `~/.aws` | block | **yes** |
| read/write/edit/bash | `~/.azure` | block | **yes** |
| read/write/edit/bash | `~/.kube` | block | **yes** |
| read/write/edit/bash | `~/.docker/config.json` | block | **yes** |
| read/write/edit/bash | `~/.netrc` | block | **yes** |
| read/write/edit/bash | `~/.npmrc` | block | **yes** |

---

## YAML configuration (reference schema)

Default rules are hardcoded in `DamageControlPolicy.swift`. The reference schema is documented at `Resources/damage-control-default.yaml`.

User-configurable overrides are planned via `~/Library/Application Support/fae/damage-control-override.json` (future). The schema follows the YAML reference:

```yaml
bashToolPatterns:
  - pattern: "regex_pattern_here"
    reason: "Human-readable reason"
    action: block | disaster | confirm_manual
    nonLocalOnly: false   # optional, default false

zeroAccessPaths:
  - path: "~/.example"
    nonLocalOnly: true

noDeletePaths:
  - path: "~/some/protected/dir/"

readOnlyPaths:   # empty by default; user-configurable
  - path: "~/important-project/"
```

**`action` values:**
- `block` — hard deny, no dialog
- `disaster` — DISASTER WARNING overlay, manual click required
- `confirm_manual` — standard manual overlay, no voice

---

## Security event log

All damage-control decisions are logged to `~/Library/Application Support/fae/security-events.jsonl` via `SecurityEventLogger`:

| Event | When |
|-------|------|
| `dc_block` | Tool call hard-blocked |
| `dc_disaster` | Disaster warning presented |
| `dc_confirm_manual` | Manual confirmation requested |

Example log entry:
```json
{
  "timestamp": "2026-03-06T10:45:22Z",
  "event": "dc_block",
  "tool_name": "bash",
  "decision": "deny",
  "reason_code": "damageControlBlock",
  "arguments_hash": "sha256:abc..."
}
```

---

## Future direction

- **User override file** — `damage-control-override.json` in the Fae support directory to add project-specific rules.
- **Co-work trust levels** — as the co-work/relay trust model matures, the `nonLocalOnly` credential blocks may expand to cover more paths or relax for explicitly trusted co-work sessions.
- **Audit dashboard** — damage-control events surfaced in Settings > Developer alongside the existing security dashboard.

---

## Implementation files

| File | Role |
|------|------|
| `Tools/DamageControlPolicy.swift` | Policy actor: three-tier verdict, locality-aware evaluation |
| `Resources/damage-control-default.yaml` | Reference schema (rules are embedded in Swift code) |
| `Tools/TrustedActionBroker.swift` | `BrokerDecision.confirm` with `manualOnly` + `isDisasterLevel` fields |
| `Pipeline/PipelineCoordinator.swift` | DC evaluation in `executeTool`; `manualOnlyApprovalPending` voice gate |
| `Agent/ApprovalManager.swift` | `requestApproval(manualOnly:isDisasterLevel:)` |
| `ApprovalOverlayController.swift` | `ApprovalRequest.manualOnly` + `.isDisasterLevel` |
| `ApprovalOverlayView.swift` | `ManualApprovalCard` + `DisasterWarningCard` |
| `Core/FaeEvent.swift` | `approvalRequested` with `manualOnly` + `isDisasterLevel` |
| `Core/FaeEventBus.swift` | Bridges new fields through the event chain |
| `BackendEventRouter.swift` | Threads `manual_only` + `disaster_level` to NotificationCenter userInfo |
