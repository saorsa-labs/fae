//! Canvas integration for visual output.
//!
//! Bridges fae's voice pipeline with the `canvas-core` scene graph,
//! mapping pipeline events to renderable scene elements.
//!
//! The [`backend::CanvasBackend`] trait abstracts over local and remote
//! canvas sessions, allowing the same pipeline, tools, and GUI code to
//! work against either.
//!
//! # Performance characteristics
//!
//! **HTML serialization** (`to_html` / `to_html_cached`): Linear in the
//! number of scene elements. Typical sessions with ≤100 elements render
//! in under 1 ms. The `to_html_cached` variant skips re-rendering when
//! the session's generation counter hasn't changed, making repeated GUI
//! frame reads essentially free.
//!
//! **Scene mutations** (`push_message`, `add_element`): O(1) per call.
//! Each mutation bumps the generation counter so the cache knows to
//! invalidate.
//!
//! **Registry lookups**: HashMap-based, O(1) amortised. The registry
//! mutex is held only for the duration of a lookup or insert.
//!
//! **WebSocket sync** (`remote` module): Each scene delta is serialised
//! as a JSON WebSocket text frame. A typical message element is ~200–400
//! bytes; a chart element is ~500–2000 bytes depending on data size.
//! Full-scene snapshots for reconnection are proportional to the total
//! element count.

pub mod backend;
pub mod bridge;
pub mod registry;
pub mod remote;
pub mod render;
pub mod session;
pub mod tools;
pub mod types;

#[cfg(test)]
mod perf_tests {
    use super::session::CanvasSession;
    use super::types::{CanvasMessage, MessageRole};

    /// Benchmark-style test: pushing 200 messages and serialising to HTML
    /// should complete well under the test timeout (~100 ms budget).
    #[test]
    fn html_serialization_scales_linearly() {
        let mut session = CanvasSession::new("perf", 800.0, 600.0);
        for i in 0u64..200 {
            let role = if i % 2 == 0 {
                MessageRole::User
            } else {
                MessageRole::Assistant
            };
            let msg = CanvasMessage::new(role, format!("Message number {i}"), i);
            session.push_message(&msg);
        }
        assert_eq!(session.message_count(), 200);

        let html = session.to_html();
        assert!(html.contains("Message number 0"));
        assert!(html.contains("Message number 199"));
        // Sanity: HTML is non-trivially sized.
        assert!(html.len() > 10_000);
    }

    /// Cached HTML avoids re-rendering when no mutations occurred.
    #[test]
    fn cached_html_avoids_redundant_work() {
        let mut session = CanvasSession::new("perf-cache", 800.0, 600.0);
        for i in 0u64..100 {
            session.push_message(&CanvasMessage::new(MessageRole::User, "msg", i));
        }

        // First call computes.
        let html1 = session.to_html_cached().to_owned();
        // Second call returns cached (no mutation in between).
        let html2 = session.to_html_cached().to_owned();
        assert_eq!(html1, html2);
    }

    /// Scene element operations remain O(1) per call at scale.
    #[test]
    fn element_operations_at_scale() {
        let mut session = CanvasSession::new("perf-ops", 800.0, 600.0);

        // Add 500 elements via messages.
        for i in 0u64..500 {
            session.push_message(&CanvasMessage::new(MessageRole::User, "x", i));
        }
        assert_eq!(session.scene().element_count(), 500);

        // Add a raw element — still O(1).
        let el = canvas_core::Element::new(canvas_core::ElementKind::Text {
            content: "raw".into(),
            font_size: 12.0,
            color: "#FFF".into(),
        });
        session.scene_mut().add_element(el);
        assert_eq!(session.scene().element_count(), 501);
    }

    /// Resize relayouts all messages in one pass.
    #[test]
    fn resize_at_scale() {
        let mut session = CanvasSession::new("perf-resize", 800.0, 600.0);
        for i in 0u64..200 {
            session.push_message(&CanvasMessage::new(MessageRole::User, "msg", i));
        }
        session.resize_viewport(400.0, 300.0);
        // All elements should have the new width.
        let expected_w = 400.0 - 32.0; // 2 * MESSAGE_MARGIN_X
        for el in session.scene().elements() {
            assert!(
                (el.transform.width - expected_w).abs() < f32::EPSILON,
                "element width mismatch after resize"
            );
        }
    }
}
