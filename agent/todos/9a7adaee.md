{
  "id": "9a7adaee",
  "title": "V3b-2: DaemonEventSubscriber (dedicated event-subscribe connection)",
  "tags": [
    "v3b",
    "swift"
  ],
  "status": "closed",
  "created_at": "2026-06-16T21:05:32.316Z"
}

DaemonEventSubscriber: dedicated daemon socket connection (own fd, not the TTS round-trip conn). auth → conversation.subscribe → read loop. Demux by event key. Dispatch audio.level(rms,playback_id) + audio.playback_ended(playback_id,reason) via callback. Own thread/task; never blocks LLM/TTS connections.
