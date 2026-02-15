# Tool Judgment Eval Suite

This suite validates the "should call a tool" vs "should not call a tool" boundary.

Test file:
- `tests/tool_judgment_eval.rs`

Run:

```bash
just tool-judgment-eval
```

Coverage design:
- Broad category mix (arithmetic, text transforms, meta prompts, static reasoning, planning, local read/write, real-time/date, web freshness, multi-step execution).
- Balanced positive/negative labels to catch both over-calling and under-calling.
- Per-category scoring in addition to aggregate metrics.

Current enforced expectations:
- Dataset size and breadth minimums (category count, per-category count, class balance).
- Perfect policy scores 100%.
- Always-call policy fails.
- Never-call policy fails.
- Local-only policy exposes web/time judgment gaps.

Why this exists:
- Small models can regress on tool judgment even when tool execution is stable.
- This suite keeps judgment quality explicit and measurable during refactors.
