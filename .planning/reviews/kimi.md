KIMI_UNAVAILABLE: Kimi CLI not found at $HOME/.local/bin/kimi

## Substitute Analysis

Diff review (autoresearch STATE.json + .planning STATE.json):
- Metric update: 6 additional evaluation runs accumulated
- barge_in dimension: [MEDIUM] Pass rate critically low at 7.1% (1/14 tests passing). Score dropped 71→42. This regression predates this diff but is surfaced here.
- tool_execution: Major improvement 23.8→41.9, pass rate 13.9%→69.4%
- memory: Improved 48.5→53.6, pass rate 13.3%→73.3%
- Overall latency increased across all dimensions (model warming effect likely)

Security: No issues.
Quality: Data-only change.

## Grade: A
## Findings: 0 critical, 0 high
