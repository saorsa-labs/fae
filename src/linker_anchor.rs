//! Linker dead-strip anchor for the Fae native library.
//!
//! # Problem
//!
//! Swift Package Manager links `libfae.a` with `-force_load` to pull all `.o`
//! files from the archive, then passes `-dead_strip` to the macOS linker which
//! removes code not reachable from exported symbols.  The only exported symbols
//! are the 8 `extern "C"` FFI functions in [`crate::ffi`].  Those functions
//! route through stub command handlers that never construct
//! [`crate::pipeline::coordinator::PipelineCoordinator`],
//! [`crate::stt::ParakeetStt`], [`crate::tts::KokoroTts`],
//! [`crate::llm::LocalLlm`], or audio subsystem types.  The linker strips all
//! ML and audio code, shrinking
//! the binary from ~100 MB to ~9 MB.
//!
//! # Solution
//!
//! [`fae_keep_alive`] is a `no_mangle` C-ABI function that holds opaque
//! references to every major subsystem constructor via
//! [`std::hint::black_box`].  The function body is guarded by
//! `black_box(false)` so it **never executes at runtime**; the guard is opaque
//! to the optimiser, which forces the linker to retain every symbol referenced
//! inside it.
//!
//! [`fae_core_init`](crate::ffi::fae_core_init) calls
//! `black_box(fae_keep_alive as *const () as usize)` to ensure the anchor
//! itself survives dead-stripping.
//!
//! # Maintenance
//!
//! When a new subsystem is added to the pipeline, add a reference to one of
//! its concrete types or constructors inside the `if black_box(false)` block.

use std::hint::black_box;

/// Prevent the macOS linker's `-dead_strip` pass from removing Rust subsystems.
///
/// # Safety
///
/// This function is safe to call — the guarded block never executes.
/// `#[unsafe(no_mangle)]` is Rust 2024 syntax for suppressing name mangling.
#[unsafe(no_mangle)]
pub extern "C" fn fae_keep_alive() {
    if black_box(false) {
        // ── Config ──────────────────────────────────────────────────────
        drop(black_box(crate::config::SpeechConfig::default()));

        // ── Pipeline coordinator ────────────────────────────────────────
        black_box(
            crate::pipeline::coordinator::PipelineCoordinator::new
                as fn(
                    crate::config::SpeechConfig,
                ) -> crate::pipeline::coordinator::PipelineCoordinator,
        );
        black_box(
            crate::pipeline::coordinator::PipelineCoordinator::with_models
                as fn(
                    crate::config::SpeechConfig,
                    crate::startup::InitializedModels,
                ) -> crate::pipeline::coordinator::PipelineCoordinator,
        );

        // ── STT (Parakeet) ──────────────────────────────────────────────
        black_box(
            crate::stt::ParakeetStt::new
                as fn(
                    &crate::config::SttConfig,
                    &crate::config::ModelConfig,
                ) -> crate::error::Result<crate::stt::ParakeetStt>,
        );

        // ── LLM (mistral.rs) ────────────────────────────────────────────
        // Async fn — take the fn item to anchor the code without calling it.
        let _llm_new = crate::llm::LocalLlm::new;
        black_box(_llm_new);

        // ── TTS (Kokoro) ────────────────────────────────────────────────
        black_box(
            crate::tts::KokoroTts::new
                as fn(&crate::config::TtsConfig) -> crate::error::Result<crate::tts::KokoroTts>,
        );

        // ── Audio capture (cpal) ────────────────────────────────────────
        black_box(
            crate::audio::capture::CpalCapture::new
                as fn(
                    &crate::config::AudioConfig,
                ) -> crate::error::Result<crate::audio::capture::CpalCapture>,
        );

        // ── Audio playback (cpal) ───────────────────────────────────────
        // CpalPlayback::new takes (AudioConfig, UnboundedSender<PlaybackEvent>)
        let _playback_new = crate::audio::playback::CpalPlayback::new;
        black_box(_playback_new);

        // ── VAD (Silero) ────────────────────────────────────────────────
        black_box(
            crate::vad::SileroVad::new
                as fn(
                    &crate::config::VadConfig,
                    &crate::config::ModelConfig,
                    u32,
                ) -> crate::error::Result<crate::vad::SileroVad>,
        );

        // ── AEC (echo cancellation) ─────────────────────────────────────
        black_box(
            crate::audio::aec::ReferenceBuffer::new
                as fn(u32, u32) -> crate::audio::aec::ReferenceBuffer,
        );
        let _aec_new = crate::audio::aec::AecProcessor::new;
        black_box(_aec_new);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify the anchor function compiles and runs without panicking.
    /// The `black_box(false)` guard ensures the inner block is never entered,
    /// so this is purely a compile-time validity check for all the type casts.
    #[test]
    fn anchor_does_not_panic() {
        fae_keep_alive();
    }

    /// Compile-time guard: these type imports must resolve.
    /// If any subsystem is removed or renamed, this test will fail to compile,
    /// alerting us that linker_anchor.rs needs updating.
    #[test]
    fn subsystem_types_exist() {
        fn _assert_types_resolve() {
            let _ = std::mem::size_of::<crate::config::SpeechConfig>();
            let _ = std::mem::size_of::<crate::pipeline::coordinator::PipelineCoordinator>();
            let _ = std::mem::size_of::<crate::stt::ParakeetStt>();
            let _ = std::mem::size_of::<crate::tts::KokoroTts>();
            let _ = std::mem::size_of::<crate::audio::capture::CpalCapture>();
            let _ = std::mem::size_of::<crate::vad::SileroVad>();
            let _ = std::mem::size_of::<crate::audio::aec::ReferenceBuffer>();
            let _ = std::mem::size_of::<crate::audio::aec::AecProcessor>();
        }
        _assert_types_resolve();
    }
}
