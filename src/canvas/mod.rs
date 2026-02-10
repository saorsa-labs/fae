//! Canvas integration for visual output.
//!
//! Bridges fae's voice pipeline with the `canvas-core` scene graph,
//! mapping pipeline events to renderable scene elements.
//!
//! The [`backend::CanvasBackend`] trait abstracts over local and remote
//! canvas sessions, allowing the same pipeline, tools, and GUI code to
//! work against either.

pub mod backend;
pub mod bridge;
pub mod registry;
pub mod remote;
pub mod render;
pub mod session;
pub mod tools;
pub mod types;
