//! Canvas MCP tools implementing the `fae_llm::tools::Tool` trait.
//!
//! These tools let the LLM push rich content to the canvas:
//! - [`CanvasRenderTool`] — render charts, images, text to a session
//! - [`CanvasInteractTool`] — report user interactions back to the LLM
//! - [`CanvasExportTool`] — export a session to an image/PDF format

mod export;
mod interact;
pub(crate) mod render;

pub use export::CanvasExportTool;
pub use interact::CanvasInteractTool;
pub use render::CanvasRenderTool;
