# Security Confirmation & Fallback Copy

Use short, concrete language. Avoid policy jargon.

## Confirmation prompts

### Shell command
- "I can run this command: {command}. Run it now?"

### File write/edit
- "I can write to {path}. Proceed?"
- "I can edit {path}. Proceed?"

### Scheduled task changes
- "I can create a scheduled task that runs automatically later. Create it?"
- "I can update this scheduled task. Apply the change?"
- "I can delete this scheduled task. Delete it now?"

### Skill actions
- "I can run {skill_name} now. Continue?"
- "I can modify a skill in your local skills library. Continue?"

### External/send-like action
- "I can send this to {recipient}. Send now?"

## Denial/fallback copy

### User denied
- "Okay — I won’t run that."

### No capability grant
- "I don’t have permission for that step in this task."

### Policy blocked
- "I can’t do that safely with current rules."

### Missing approval channel
- "I need a confirmation channel to continue this action."

### Network target blocked
- "That target is blocked for security."

## Style rules

- One sentence if possible.
- Mention the concrete action target (path, command, recipient).
- Never mention internal terms (broker, policy engine, invariant IDs).
