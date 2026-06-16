//! Server-push event fan-out for the `conversation.subscribe` stream (voice
//! spine V2).
//!
//! All outbound bytes on a connection — request responses AND unsolicited
//! events — funnel through one per-connection writer task ([`ConnSink`]), so an
//! async event push (e.g. an `audio.level` envelope during playback) can never
//! interleave mid-frame with a response. The [`EventBus`] holds only `Weak`
//! references to subscriber sinks, so a closed connection is pruned
//! automatically on the next publish — no explicit unregister. A subscriber
//! receives an event only when it was granted the event's required [`Scope`].

use std::collections::{HashMap, HashSet};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, Weak};

use fae_audio::PlaybackId;
use fae_control_plane::{Event, Scope};
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

/// A line-oriented outbound sink for one connection. Delivery is non-blocking
/// (an unbounded channel drained by the writer task); per-connection ordering
/// is preserved.
pub trait EventSink: Send + Sync {
    /// Queue one already-serialized NDJSON line (trailing newline included).
    fn deliver(&self, line: &Arc<Vec<u8>>);
}

/// Owns a connection's writer task. The response path and the event path both
/// send through `tx`, so a single task serializes every write to the socket and
/// frames never interleave.
pub struct ConnSink {
    tx: mpsc::UnboundedSender<Arc<Vec<u8>>>,
}

impl ConnSink {
    /// Spawn the writer task draining queued lines to `writer`. Returns the sink
    /// and the task handle; dropping every reference to the sink closes the
    /// channel and ends the task once the backlog is flushed.
    pub fn spawn<W>(mut writer: W) -> (Arc<ConnSink>, JoinHandle<()>)
    where
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (tx, mut rx) = mpsc::unbounded_channel::<Arc<Vec<u8>>>();
        let handle = tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                if writer.write_all(&line).await.is_err() {
                    break;
                }
                if writer.flush().await.is_err() {
                    break;
                }
            }
        });
        (Arc::new(ConnSink { tx }), handle)
    }

    /// Queue one line on the connection (request responses).
    pub fn send_line(&self, line: Arc<Vec<u8>>) {
        let _ = self.tx.send(line);
    }
}

impl EventSink for ConnSink {
    fn deliver(&self, line: &Arc<Vec<u8>>) {
        let _ = self.tx.send(Arc::clone(line));
    }
}

// Fields are read by `publish`/`subscriber_count`, which have no non-test caller
// until V3 wires the first producer (daemon-owned TTS playback → `audio.level`).
#[allow(dead_code)]
struct Subscriber {
    sink: Weak<dyn EventSink>,
    scopes: HashSet<Scope>,
}

/// Fan-out of server-push events to subscribed connections. Cheap to clone
/// (shares one subscriber list) — held by the transport to register subscribers
/// and, later, by event producers to publish.
#[derive(Clone, Default)]
pub struct EventBus {
    subscribers: Arc<Mutex<Vec<Subscriber>>>,
}

impl EventBus {
    #[must_use]
    pub fn new() -> EventBus {
        EventBus::default()
    }

    /// Register a connection's sink with the scopes it was granted. Only a
    /// `Weak` ref is kept, so the bus never keeps a closed connection alive.
    pub fn subscribe(&self, sink: Weak<dyn EventSink>, scopes: HashSet<Scope>) {
        if let Ok(mut subs) = self.subscribers.lock() {
            subs.push(Subscriber { sink, scopes });
        }
    }

    /// Publish `event` to every live subscriber that holds `required`. Dead
    /// (dropped) subscribers are pruned in the same pass. A serialization
    /// failure drops the event rather than tearing down any connection.
    ///
    /// Producer: voice spine V3a `tts.speak` publishes `audio.level` (per RMS
    /// reading) and `audio.playback_ended` (on close) on this bus.
    pub fn publish(&self, event: &str, required: Scope, payload: serde_json::Value) {
        let frame = Event::new(event, payload);
        let line = match serde_json::to_vec(&frame) {
            Ok(mut bytes) => {
                bytes.push(b'\n');
                Arc::new(bytes)
            }
            Err(_) => return,
        };
        if let Ok(mut subs) = self.subscribers.lock() {
            subs.retain(|sub| match sub.sink.upgrade() {
                Some(sink) => {
                    if sub.scopes.contains(&required) {
                        sink.deliver(&line);
                    }
                    true
                }
                None => false,
            });
        }
    }

    /// Live subscriber count, pruning dead entries. Diagnostic/test use.
    #[must_use]
    #[allow(dead_code)]
    pub fn subscriber_count(&self) -> usize {
        if let Ok(mut subs) = self.subscribers.lock() {
            subs.retain(|sub| sub.sink.strong_count() > 0);
            subs.len()
        } else {
            0
        }
    }
}

/// Daemon-side bookkeeping for live daemon-owned playbacks (voice spine V3a).
/// The [`fae_audio`] layer closes the RMS `level` channel identically whether a
/// clip finished naturally or was barged in, so the end-reason (`completed` vs
/// `interrupted`) is resolved here: `audio.stop` flips the interrupted flag
/// *before* stopping the stream, and the level-drain task reads it when the
/// channel closes. Process-global (a `tts.speak` and its `audio.stop` may arrive
/// on different connections) and cheap to clone (one shared map).
#[derive(Clone, Default)]
pub struct PlaybackRegistry {
    inner: Arc<Mutex<HashMap<PlaybackId, Arc<AtomicBool>>>>,
}

impl PlaybackRegistry {
    #[must_use]
    pub fn new() -> PlaybackRegistry {
        PlaybackRegistry::default()
    }

    /// Register a freshly started playback and return the shared interrupted
    /// flag the level-drain task will read at end-of-stream.
    pub fn insert(&self, id: PlaybackId) -> Arc<AtomicBool> {
        let flag = Arc::new(AtomicBool::new(false));
        if let Ok(mut map) = self.inner.lock() {
            map.insert(id, Arc::clone(&flag));
        }
        flag
    }

    /// Mark a playback interrupted. Returns `true` if the id was live (so the
    /// caller can distinguish "stopped a real playback" from a stale id).
    pub fn mark_interrupted(&self, id: &str) -> bool {
        if let Ok(map) = self.inner.lock() {
            if let Some(flag) = map.get(id) {
                flag.store(true, std::sync::atomic::Ordering::Relaxed);
                return true;
            }
        }
        false
    }

    /// All live playback ids (for `audio.stop` with no `playback_id`).
    pub fn ids(&self) -> Vec<PlaybackId> {
        self.inner
            .lock()
            .map(|map| map.keys().cloned().collect())
            .unwrap_or_default()
    }

    /// Remove a playback (called by the level-drain task once the `level`
    /// channel has closed and the end-reason has been published).
    pub fn remove(&self, id: &str) {
        if let Ok(mut map) = self.inner.lock() {
            map.remove(id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sink that captures delivered lines without touching a socket.
    struct MockSink {
        lines: Mutex<Vec<Vec<u8>>>,
    }

    impl MockSink {
        fn new() -> Arc<MockSink> {
            Arc::new(MockSink {
                lines: Mutex::new(Vec::new()),
            })
        }
        fn count(&self) -> usize {
            self.lines.lock().map(|l| l.len()).unwrap_or(0)
        }
    }

    impl EventSink for MockSink {
        fn deliver(&self, line: &Arc<Vec<u8>>) {
            if let Ok(mut lines) = self.lines.lock() {
                lines.push(line.as_ref().clone());
            }
        }
    }

    fn scope_set(scopes: &[Scope]) -> HashSet<Scope> {
        scopes.iter().copied().collect()
    }

    #[test]
    fn publish_delivers_only_to_subscribers_holding_the_required_scope() {
        let bus = EventBus::new();
        let allowed = MockSink::new();
        let denied = MockSink::new();
        let allowed_dyn: Arc<dyn EventSink> = allowed.clone();
        let denied_dyn: Arc<dyn EventSink> = denied.clone();
        bus.subscribe(
            Arc::downgrade(&allowed_dyn),
            scope_set(&[Scope::AudioPlayback]),
        );
        bus.subscribe(
            Arc::downgrade(&denied_dyn),
            scope_set(&[Scope::ConversationRead]),
        );

        bus.publish(
            "audio.level",
            Scope::AudioPlayback,
            serde_json::json!({ "rms": 0.4 }),
        );

        assert_eq!(allowed.count(), 1, "scoped subscriber receives the event");
        assert_eq!(denied.count(), 0, "unscoped subscriber is filtered out");
    }

    #[test]
    fn dropped_subscriber_is_pruned_on_next_publish() {
        let bus = EventBus::new();
        let sink = MockSink::new();
        let sink_dyn: Arc<dyn EventSink> = sink.clone();
        bus.subscribe(
            Arc::downgrade(&sink_dyn),
            scope_set(&[Scope::AudioPlayback]),
        );
        assert_eq!(bus.subscriber_count(), 1);

        drop(sink_dyn);
        drop(sink);
        bus.publish("audio.level", Scope::AudioPlayback, serde_json::json!({}));
        assert_eq!(bus.subscriber_count(), 0, "dead subscriber pruned");
    }

    #[tokio::test]
    async fn conn_sink_writes_a_framed_event_line_through_the_writer_task() {
        use tokio::io::AsyncReadExt;

        let (mut client, server) = tokio::io::duplex(4096);
        let (sink, _handle) = ConnSink::spawn(server);
        let sink_dyn: Arc<dyn EventSink> = sink.clone();
        let bus = EventBus::new();
        bus.subscribe(
            Arc::downgrade(&sink_dyn),
            scope_set(&[Scope::AudioPlayback]),
        );

        bus.publish(
            "audio.level",
            Scope::AudioPlayback,
            serde_json::json!({ "rms": 0.42 }),
        );

        let mut buf = vec![0u8; 256];
        let n = client.read(&mut buf).await.expect("read pushed event");
        let line = std::str::from_utf8(&buf[..n]).expect("utf8");
        assert!(line.contains("\"event\":\"audio.level\""), "line: {line}");
        assert!(line.contains("\"rms\":0.42"), "line: {line}");
        assert!(line.ends_with('\n'), "frames are newline-delimited");
    }
}
