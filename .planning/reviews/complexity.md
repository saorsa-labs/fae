# Complexity Review
**Date**: 2026-02-19
**Mode**: gsd-task

## File Sizes
- src/host/handler.rs: 1187 lines
- src/host/channel.rs: 1181 lines

## Findings

- [MEDIUM] src/host/handler.rs: request_runtime_start() spans ~238 lines (441-679). The inline ProgressEvent match inside the async closure (~90 lines, 499-592) is the primary complexity contributor. Should be extracted to progress_event_to_json().
- [LOW] src/host/handler.rs: map_runtime_event() is ~140 lines but is a flat match with 26 arms — acceptable and necessary.
- [MEDIUM] FaeDeviceTransferHandler has 11 fields, 8 Mutex-wrapped Options. A PipelineInner inner struct would reduce complexity and enable atomic multi-field updates.
- [OK] src/host/channel.rs: All handler functions are 10-20 lines each — good.
- [MEDIUM] request_runtime_start() has 6 levels of nesting at deepest point (function → async closure → match → variant arm → json! → value)

## Grade: B
