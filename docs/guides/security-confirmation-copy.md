# Security Confirmation & Fallback Copy

Use short, concrete language. Avoid policy jargon.

## Confirmation prompts

### Shell command
- "I can run this command: {command}. Say yes or no, or press the Yes/No button."

### File write/edit
- "I can write to {path}. Say yes or no, or press the Yes/No button."
- "I can edit {path}. Say yes or no, or press the Yes/No button."

### Scheduled task changes
- "I can create a scheduled task that runs automatically later. Say yes or no, or press the Yes/No button."
- "I can update this scheduled task. Say yes or no, or press the Yes/No button."
- "I can delete this scheduled task. Say yes or no, or press the Yes/No button."

### Skill actions
- "I can run {skill_name} now. Say yes or no, or press the Yes/No button."
- "I can modify a skill in your local skills library. Say yes or no, or press the Yes/No button."

### External/send-like action
- "I can send this to {recipient}. Say yes or no, or press the Yes/No button."

## Denial/fallback copy

### User denied
- "Okay — I won’t run that."

### No capability grant
- "I don’t have permission for that step in this task."

### Policy blocked
- "I can’t do that safely with current rules."

### Missing approval channel
- "I need a confirmation channel to continue this action."

### Tool-backed lookup did not run
- "I need to check that with a tool before I answer, and I couldn’t run it this turn. Please ask me to try again."

### Owner enrollment required
- "I need to enroll your primary voice before I can run tools for that. Please complete voice enrollment, then ask me again."

### Background lookup acknowledged
- "I’ll check that in the background and report back as soon as it’s ready."

### Network target blocked
- "That target is blocked for security."

## Style rules

- One sentence if possible.
- Mention the concrete action target (path, command, recipient).
- For confirmation prompts, explicitly include "yes or no" and reference the Yes/No button path.
- Never mention internal terms (broker, policy engine, invariant IDs).
