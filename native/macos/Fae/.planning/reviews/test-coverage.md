# Test Coverage Review
**Date**: 2026-03-30
**Mode**: gsd — Phase 1.1

## Test files in Tests/IntegrationTests/:
EndToEndAllowWithTransformTests.swift
EndToEndApprovalFlowTests.swift
EndToEndApprovalProgressionTests.swift
EndToEndBashReversibilityTests.swift
EndToEndBatchUndoTests.swift
EndToEndBuiltInAwarenessTaskTests.swift
EndToEndConversationRoutingFlowTests.swift
EndToEndIrreversibleCountdownTests.swift
EndToEndMemoryFlowTests.swift
EndToEndNarrationAndBargeInTests.swift
EndToEndOwnerSilentModeTests.swift
EndToEndProactiveAwarenessRoutingTests.swift
EndToEndSchedulerAutonomyTests.swift
EndToEndSchedulerFlowTests.swift
EndToEndSchedulerPersistenceStressTests.swift
EndToEndTextToolFlowTests.swift
EndToEndVoiceIdentityTests.swift
Harness
ParakeetStreamingEngineTests.swift
PluginLoaderTests.swift
UVRuntimeTests.swift

## AdapterLoadingTests.swift exists:
NO — not created

## Total test functions in FaeTests:
1683 test functions total

## Adapter-related tests:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/DryRunModeTests.swift:        // Dry-run now returns a valid JSON envelope so typed adapters work.
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        ChannelGateway, ChannelSessionStore, ConcurrencyMockAdapter,
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        ConcurrencyMockAdapter, ConcurrencyMockAdapter
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        let discord = ConcurrencyMockAdapter(kind: .discord)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        let whatsapp = ConcurrencyMockAdapter(kind: .whatsapp)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        let imessage = ConcurrencyMockAdapter(kind: .imessage)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        await gateway.registerAdapter(discord)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        await gateway.registerAdapter(discord)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        await gateway.registerAdapter(whatsapp)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Tests/HandoffTests/ChannelConcurrencyTests.swift:        await gateway.registerAdapter(imessage)

## Findings
- [CRITICAL] Phase 1.1 Task 5 NOT DONE: AdapterLoadingTests.swift not created. 0/6 required test cases written.
  Required tests missing:
  - loadAdapter(from:) with valid mock adapter directory
  - loadAdapter(from:) with nonexistent directory throws typed error
  - loadAdapter(from:) with missing adapter_config.json throws typed error
  - unloadAdapter() when no adapter loaded is safe no-op
  - swapAdapter(to:) replaces current adapter
  - adapter loading resets KV cache (sessionState cleared)

## Grade: F (0 adapter tests written)
