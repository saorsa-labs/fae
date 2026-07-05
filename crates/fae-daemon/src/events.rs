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

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use fae_audio::PlaybackId;
use fae_control_plane::{Event, Scope};
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, Notify};
use tokio::task::JoinHandle;

/// Bound on the per-connection lossy event queue (`audio.level` et al.). At the
/// V3 RMS publish rate (~tens of frames/sec) this is a few seconds of backlog;
/// beyond it a stalled reader sheds the OLDEST samples so the freshest levels —
/// and any terminal `audio.playback_ended` — always win, and RSS is bounded no
/// matter how long the reader stalls.
const EVENT_QUEUE_CAP: usize = 256;

/// A line-oriented outbound sink for one connection. Delivery of an event is
/// non-blocking and LOSSY: events ride a bounded [drop-oldest](EventQueue) lane
/// so a stalled reader can never grow RSS without bound. Per-lane ordering is
/// preserved. Request responses use [`ConnSink::send_line`] (the reliable lane).
pub trait EventSink: Send + Sync {
    /// Queue one already-serialized NDJSON event line (trailing newline
    /// included) on the lossy lane. Dropped (oldest-first) if the reader has
    /// stalled past [`EVENT_QUEUE_CAP`].
    fn deliver(&self, line: &Arc<Vec<u8>>);
}

/// The lossy lane's bounded ring buffer. `deliver` pushes; the writer task
/// drains. On overflow the OLDEST frame is evicted (drop-oldest) so the newest
/// frames — including any terminal `audio.playback_ended` — survive.
struct EventQueue {
    ring: Mutex<VecDeque<Arc<Vec<u8>>>>,
    notify: Notify,
    dropped: AtomicU64,
}

impl EventQueue {
    fn new() -> EventQueue {
        EventQueue {
            ring: Mutex::new(VecDeque::new()),
            notify: Notify::new(),
            dropped: AtomicU64::new(0),
        }
    }

    /// Enqueue a lossy frame, evicting the oldest if already at capacity, then
    /// wake the writer. Bounds the queue at [`EVENT_QUEUE_CAP`].
    fn push(&self, line: Arc<Vec<u8>>) {
        if let Ok(mut ring) = self.ring.lock() {
            while ring.len() >= EVENT_QUEUE_CAP {
                ring.pop_front();
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
            ring.push_back(line);
        }
        self.notify.notify_one();
    }

    fn pop(&self) -> Option<Arc<Vec<u8>>> {
        self.ring.lock().ok().and_then(|mut r| r.pop_front())
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.ring.lock().map(|r| r.len()).unwrap_or(0)
    }

    #[cfg(test)]
    fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

/// Owns a connection's writer task. A single task serializes every write, so
/// frames never interleave mid-frame. Two lanes feed it: the RELIABLE lane
/// (`tx`, request responses/control — never dropped) and the LOSSY `events`
/// lane (bounded, drop-oldest — high-rate `audio.level`). Reliable frames are
/// prioritized; the lossy lane bounds RSS under a stalled reader.
pub struct ConnSink {
    tx: mpsc::UnboundedSender<Arc<Vec<u8>>>,
    events: Arc<EventQueue>,
}

impl ConnSink {
    /// Spawn the writer task draining both lanes to `writer`. Returns the sink
    /// and the task handle; dropping every reference to the sink closes the
    /// reliable channel, which drains any remaining events and ends the task.
    pub fn spawn<W>(mut writer: W) -> (Arc<ConnSink>, JoinHandle<()>)
    where
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (tx, mut rx) = mpsc::unbounded_channel::<Arc<Vec<u8>>>();
        let events = Arc::new(EventQueue::new());
        let events_task = Arc::clone(&events);
        let handle = tokio::spawn(async move {
            loop {
                // Reliable frames take priority; the lossy lane drains when the
                // reliable lane is idle. Either way the writer emits ONE
                // complete line at a time, so frames never interleave mid-frame.
                tokio::select! {
                    biased;
                    reliable = rx.recv() => {
                        match reliable {
                            Some(line) => {
                                if writer.write_all(&line).await.is_err()
                                    || writer.flush().await.is_err()
                                {
                                    break;
                                }
                            }
                            None => {
                                // Sink dropped (connection teardown): flush any
                                // buffered events best-effort, then exit.
                                while let Some(line) = events_task.pop() {
                                    if writer.write_all(&line).await.is_err()
                                        || writer.flush().await.is_err()
                                    {
                                        break;
                                    }
                                }
                                break;
                            }
                        }
                    }
                    () = events_task.notify.notified() => {
                        while let Some(line) = events_task.pop() {
                            if writer.write_all(&line).await.is_err()
                                || writer.flush().await.is_err()
                            {
                                return;
                            }
                        }
                    }
                }
            }
        });
        (Arc::new(ConnSink { tx, events }), handle)
    }

    /// Queue one line on the RELIABLE lane (request responses/control). Never
    /// dropped — bounded in practice by the client's request rate.
    pub fn send_line(&self, line: Arc<Vec<u8>>) {
        let _ = self.tx.send(line);
    }
}

impl EventSink for ConnSink {
    fn deliver(&self, line: &Arc<Vec<u8>>) {
        self.events.push(Arc::clone(line));
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

    #[test]
    fn event_queue_is_bounded_and_drops_oldest_under_a_stalled_reader() {
        let q = EventQueue::new();
        // Push well past capacity with no reader draining (a stalled reader):
        // each frame's payload encodes its index so we can prove WHICH frames
        // survived. Unbounded growth is the bug; this asserts the bound + that
        // the OLDEST frames — not the newest — are the ones shed.
        let overflow = EVENT_QUEUE_CAP + 100;
        for i in 0..overflow {
            q.push(Arc::new((i as u32).to_le_bytes().to_vec()));
        }
        assert_eq!(q.len(), EVENT_QUEUE_CAP, "queue is bounded at capacity");
        assert_eq!(
            q.dropped(),
            (overflow - EVENT_QUEUE_CAP) as u64,
            "the overflow frames were dropped, not queued",
        );
        // The first RETAINED frame is index `overflow - CAP` (drop-oldest keeps
        // the freshest window), never index 0 (which would be drop-newest).
        let expected_first = (overflow - EVENT_QUEUE_CAP) as u32;
        let first = q.pop().expect("queue holds the freshest frames");
        assert_eq!(
            first.as_ref(),
            &expected_first.to_le_bytes().to_vec(),
            "oldest surviving frame is the first one NOT evicted",
        );
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
