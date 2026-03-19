---
name: email-triage
description: AI-driven email inbox triage — prioritise, categorise, and action emails using Apple Mail.
metadata:
  author: fae
  version: "1.0"
---

# Email Triage

You are triaging the user's email inbox. Use the `mail` tool to read and manage emails. Everything stays local via Apple Mail — no external email APIs.

## Activation

User says: "check my email", "triage my inbox", "what emails need attention", "sort my mail".

## Triage Protocol

### Step 1: Scan inbox

Use `mail` tool with action `list` to get recent unread emails. Request the last 20-50 unread messages.

### Step 2: Categorise each email

Assign each email to exactly one category:

| Priority | Category | Action |
|----------|----------|--------|
| P1 | **Urgent — needs reply today** | Direct from people you know, time-sensitive requests, meeting changes today |
| P2 | **Important — reply this week** | Work requests, personal messages, bills due soon |
| P3 | **Informational — read when free** | Newsletters you subscribe to, updates, FYI threads |
| P4 | **Low value — archive or delete** | Marketing, spam that passed filters, automated notifications |

### Step 3: Present summary

Format as a brief spoken summary:

"You have 23 unread emails. 2 are urgent: [brief description]. 5 are important — mostly work requests. The rest are newsletters and notifications. Want me to go through the urgent ones?"

### Step 4: Act on user's instructions

Based on user response:
- **"Read me the urgent ones"** — read P1 emails aloud, one at a time
- **"Draft a reply"** — compose a reply using `mail` tool with action `send`
- **"Archive the junk"** — use `mail` tool to archive P4 emails
- **"Flag the important ones"** — use `mail` tool to flag P2 emails

## Memory Integration

Learn the user's patterns over time:
- Remember which senders are always P1 (boss, partner, etc.)
- Remember which newsletters the user always skips
- Adjust categorisation based on past triage decisions

After first triage session, offer: "Want me to remember your email priorities so future triage is faster?"

## Constraints

- Use ONLY the local Apple Mail integration. No external email APIs.
- NEVER forward, CC, or BCC emails without explicit user approval.
- For sensitive emails (financial, medical, legal), read the subject but ask before reading the full body aloud.
- Triage is a suggestion — the user always decides what to do with each email.
