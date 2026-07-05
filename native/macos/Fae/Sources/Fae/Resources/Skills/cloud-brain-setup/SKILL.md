---
name: cloud-brain-setup
description: Conversationally set up (or turn off) a cloud brain for harder questions via OpenRouter. Privacy-first, plain language, no jargon. Use when the user wants a bigger/smarter brain, mentions the cloud, or asks Fae to think harder on tough questions.
metadata:
  author: fae
  version: "1.0"
---

You are helping the user add a **cloud brain** — a bigger model Fae can reach for
the occasional hard question. This is a warm, plain-language conversation, not a
technical setup wizard. The person may not know what an API key is. Never assume
they do.

## What this is (say it simply)

- By default you run entirely on their machine. Nothing they say leaves the Mac.
- A cloud brain is an *optional* bigger model for hard questions — deeper
  research, tricky reasoning — when the local model would struggle.
- The local brain stays the default. The cloud is only used when they explicitly
  ask ("ask the cloud…", "use the cloud…"), never on its own.

## Privacy first — lead with this, always

Say this in your own warm words before anything else:

- "The local model stays your default — this only kicks in when you ask for it."
- "Everything still goes through my privacy filter first, so personal details are
  stripped before anything is sent."
- "It goes to OpenRouter, which is GDPR-friendly and used by lots of people in the
  EU — but I'll only ever use it for the questions you point at it."

If they hesitate at all, reassure them they can turn it off any time with one
sentence (see **Turning it off** below), and that saying no changes nothing —
you keep working exactly as you do now.

## The flow (only if they say yes)

### 1. Do they have a key?

Ask, simply: "Do you already have an OpenRouter key, or should I walk you through
getting one?" Most people won't have one — that's fine.

### 2. Walk them through getting a key (if needed)

Read it out one step at a time, unhurried:

1. "Go to **openrouter.ai** in your browser."
2. "Sign in — you can use Google or GitHub, whichever's easiest."
3. "Click your avatar, then **Keys**, then **Create Key**. Give it any name, like
   'Fae'."
4. "Copy the key it shows you — it starts with `sk-or-`. Don't read it out to me;
   I'll give you a private box to paste it into."

Mention OpenRouter usually needs a small amount of credit added to work, and that
they stay in control of spending — you keep a small daily cap.

### 3. Collect the key SECURELY — never any other way

**Always** collect the key with an `input_request` card, never by asking them to
say it aloud or type it into the chat:

```
input_request(
  title: "OpenRouter Key",
  prompt: "Paste your OpenRouter key here — it starts with sk-or-. This is stored securely on your Mac and never shown back to you.",
  placeholder: "sk-or-...",
  secure: true,
  store_key: "openrouter.apiKey"
)
```

- `secure: true` masks the value as they paste.
- `store_key: "openrouter.apiKey"` saves it straight to the macOS Keychain — the
  raw value is never returned to you and never enters our conversation.
- If they cancel, acknowledge it kindly and stop. Don't ask again right away.

### 4. Turn the cloud lane on

Once the key is stored, enable cloud routing:

```
self_config(key: "llm.privacy_lane", value: "all")
```

(Use `"all"` to allow the cloud lane. `"local"` keeps everything on-device.)

### 5. Wake the connection

Tell them warmly: **"Give me a few seconds to wake my cloud connection."** Setting
the privacy lane above triggers that automatically in the background — you don't
need to call anything else. It finishes within a few seconds and won't interrupt
anything you're in the middle of.

### 6. Close the loop

Tell them plainly what changed and how to use it:

- "Done — the cloud brain is ready."
- "Your local model is still the default. When you want the bigger brain, just
  start with **'ask the cloud…'** — like 'ask the cloud to research X'."
- "Everything still goes through my privacy filter first."
- "To switch it off any time, just say: **'stop using cloud models'**."

## Turning it off (the reverse flow)

If the user says "stop using cloud models" / "turn off the cloud" / "go
local-only":

1. Set the lane back to local:
   ```
   self_config(key: "llm.privacy_lane", value: "local")
   ```
2. Confirm: "You're fully local again — nothing will go to the cloud." (This also
   wakes the local-only connection in the background, same few seconds.)
3. Offer, but don't force, key removal: "Want me to forget the saved key too, or
   keep it in case you turn this back on later?" Only remove it if they say yes —
   deleting the Keychain key is done via the normal credential-management path,
   not by you reading or handling the value.

## Guardrails

- Never ask the user to speak or type a key into the conversation. Always the
  secure `input_request` card with `store_key`.
- Never echo, repeat, or confirm the key's contents — just confirm you received
  it.
- Never claim the cloud is "always on" or that it replaces the local model. It's
  opt-in, per-question, privacy-filtered.
- If they seem unsure, it's completely fine to leave things local. Say so.
