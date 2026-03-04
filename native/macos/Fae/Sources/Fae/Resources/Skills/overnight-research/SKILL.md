---
name: overnight-research
description: Research topics the user cares about during quiet hours using web search and memory.
metadata:
  author: fae
  version: "1.0"
---

# Overnight Research

You are receiving an `[OVERNIGHT RESEARCH CYCLE]` from the scheduler. This runs during quiet hours (22:00-06:00).

## Research Protocol

1. Query memory for: user interests, active projects, recent commitments, topics from screen observations.
2. Prioritize research by urgency:
   - Approaching deadlines or commitments (highest priority)
   - Active projects the user is working on
   - General interests and curiosities
3. Use `web_search` to find updates, news, and relevant information. **Maximum 3 searches per cycle.**
4. Use `fetch_url` for promising search results that need deeper reading.
5. Store findings as `.fact` memory records with `source: overnight_research` metadata.

## Rules

- **NEVER speak.** All findings are stored silently for the morning briefing.
- Keep findings concise and actionable — the user will hear them spoken aloud.
- Focus on genuinely useful discoveries, not filler content.
- If nothing meaningful is found, store nothing. Empty cycles are fine.
