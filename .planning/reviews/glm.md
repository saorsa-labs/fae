# GLM-4.7 External Review
**Date**: 2026-02-19
**Status**: GLM_UNAVAILABLE — manual fallback

## Findings

- [MEDIUM] Double event emission via command channel path: FaeDeviceTransferHandler::request_runtime_start emits "runtime.starting" + "runtime.started", then HostCommandServer::handle_runtime_start emits another "runtime.started". Consumer receives 3 events for 1 command. Duplicate "started" may cause UI state bugs.
- [OK] command_channel_with_events() properly shares event_tx between client and server.
- [LOW] progress_tx is cloned inside async closure from event_tx clone. Minor extra clone — could be moved directly.

## Grade: B+
