//! Server-initiated requests (daemon → client), gap A3.
//!
//! Until now the protocol was one-directional: clients send commands and the
//! daemon replies, plus one-way server-push events. A delegated agent can ask
//! the *client* to make decisions mid-turn — `session/request_permission`
//! (approve a tool call) and `fs/read_text_file` / `fs/write_text_file`. Those
//! must reach Fae (the approval card, the path/damage policy) and the answer
//! must flow back into the agent's turn.
//!
//! Mechanism: the daemon writes a request frame
//! `{v, server_request_id, method, params}` on the connection's writer sink and
//! parks a oneshot keyed by `server_request_id`. The connection's read loop —
//! kept reading because the long `agent.prompt` runs on a spawned task — sees the
//! client's reply frame `{v, server_request_id, result}` and resolves the
//! oneshot. Point-to-point on the one connection that owns the turn; no
//! broadcast.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::oneshot;

use crate::events::ConnSink;

/// A server-initiated request failed to get a reply.
#[derive(Debug)]
pub enum ServerRequestError {
    /// The connection closed (or the read loop ended) before the reply arrived.
    Disconnected,
}

/// Per-connection issuer of server-initiated requests. Cheap to clone (shared
/// pending map + counter); the spawned `agent.prompt` task holds one to drive
/// the agent's permission / fs round-trips.
#[derive(Clone)]
pub struct ServerRequester {
    sink: Arc<ConnSink>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<serde_json::Value>>>>,
    counter: Arc<AtomicU64>,
}

impl ServerRequester {
    #[must_use]
    pub fn new(sink: Arc<ConnSink>) -> ServerRequester {
        ServerRequester {
            sink,
            pending: Arc::new(Mutex::new(HashMap::new())),
            counter: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Send a request to the client and await its reply payload. The future
    /// resolves when the read loop routes the matching reply via [`resolve`].
    ///
    /// [`resolve`]: ServerRequester::resolve
    pub async fn request(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, ServerRequestError> {
        let id = format!("sr-{}", self.counter.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = oneshot::channel();
        if let Ok(mut pending) = self.pending.lock() {
            pending.insert(id.clone(), tx);
        }
        let frame = serde_json::json!({
            "v": 2,
            "server_request_id": id,
            "method": method,
            "params": params,
        });
        match serde_json::to_vec(&frame) {
            Ok(mut bytes) => {
                bytes.push(b'\n');
                self.sink.send_line(Arc::new(bytes));
            }
            Err(_) => {
                // Drop the parked oneshot; serialization can't recover.
                if let Ok(mut pending) = self.pending.lock() {
                    pending.remove(&id);
                }
                return Err(ServerRequestError::Disconnected);
            }
        }
        rx.await.map_err(|_| ServerRequestError::Disconnected)
    }

    /// Resolve a pending request with the client's reply (called by the read
    /// loop on a `{server_request_id, result}` frame). Unknown ids are ignored.
    pub fn resolve(&self, server_request_id: &str, result: serde_json::Value) {
        if let Ok(mut pending) = self.pending.lock() {
            if let Some(tx) = pending.remove(server_request_id) {
                let _ = tx.send(result);
            }
        }
    }
}

/// A reply frame to a server-initiated request, distinguished from a command by
/// the presence of `server_request_id`.
#[derive(serde::Deserialize)]
pub struct ServerReply {
    pub server_request_id: String,
    #[serde(default)]
    pub result: serde_json::Value,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn request_frames_carry_method_and_resolve_on_reply() {
        let (mut client, server) = tokio::io::duplex(4096);
        let (sink, _writer) = ConnSink::spawn(server);
        let requester = ServerRequester::new(sink);

        let driver = requester.clone();
        let task = tokio::spawn(async move {
            driver
                .request("permission.request", serde_json::json!({ "n": 1 }))
                .await
        });

        // The request frame should be written to the connection.
        let mut buf = vec![0u8; 512];
        let n = client.read(&mut buf).await.expect("read request frame");
        let line = std::str::from_utf8(&buf[..n]).expect("utf8");
        assert!(line.contains("\"method\":\"permission.request\""), "{line}");
        let frame: serde_json::Value = serde_json::from_str(line.trim()).expect("json");
        let id = frame["server_request_id"].as_str().expect("id").to_owned();

        // Resolving with the reply payload completes the awaiting request.
        requester.resolve(&id, serde_json::json!({ "approved": true }));
        let result = task.await.expect("join").expect("reply");
        assert_eq!(result["approved"], serde_json::json!(true));
    }

    #[tokio::test]
    async fn server_reply_frame_parses_only_with_id() {
        assert!(serde_json::from_str::<ServerReply>(
            r#"{"v":2,"server_request_id":"sr-0","result":{"ok":true}}"#
        )
        .is_ok());
        // A command frame (no server_request_id) must not parse as a reply.
        assert!(serde_json::from_str::<ServerReply>(
            r#"{"v":2,"request_id":"r1","command":"host.ping","payload":{}}"#
        )
        .is_err());
    }
}
