//! CLI binary for fae.

use clap::{Parser, Subcommand};
use fae::audio::capture::CpalCapture;
use fae::audio::playback::CpalPlayback;
use fae::{PipelineCoordinator, PipelineMode, SpeechConfig};
use std::path::PathBuf;
use tracing::info;
use tracing_subscriber::EnvFilter;

/// Fae: Real-time speech-to-speech AI conversation system.
#[derive(Parser)]
#[command(name = "fae", version, about)]
struct Cli {
    /// Path to TOML configuration file.
    #[arg(short, long)]
    config: Option<PathBuf>,

    /// Subcommand to run.
    #[command(subcommand)]
    command: Option<Command>,
}

/// Available commands.
#[derive(Subcommand)]
enum Command {
    /// Start a voice conversation with the AI.
    Chat,

    /// List available audio devices.
    Devices,

    /// Run in transcription-only mode (no LLM/TTS).
    Transcribe,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize tracing — suppress noisy dependency logs by default.
    // Users can override with RUST_LOG=debug to see everything.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                EnvFilter::new("fae=info,hf_hub=warn,ort=warn,candle_core=warn,candle_nn=warn,candle_transformers=warn")
            }),
        )
        .init();

    let cli = Cli::parse();

    // Load config
    let config = if let Some(ref path) = cli.config {
        SpeechConfig::from_file(path)?
    } else {
        SpeechConfig::default()
    };

    match cli.command.unwrap_or(Command::Chat) {
        Command::Chat => run_chat(config).await,
        Command::Devices => list_devices(),
        Command::Transcribe => run_transcribe(config).await,
    }
}

async fn run_chat(config: SpeechConfig) -> anyhow::Result<()> {
    println!("Fae v{}", env!("CARGO_PKG_VERSION"));

    // Capture conversation config before moving config into the pipeline
    let gate_enabled = config.conversation.enabled;
    let wake_word_display = capitalize(&config.conversation.wake_word);
    let stop_phrase_display = config.conversation.stop_phrase.clone();

    // Phase 1: Download & load models with progress
    let models = fae::startup::initialize_models(&config).await?;

    // Phase 2: Run pipeline with pre-loaded models
    let pipeline =
        PipelineCoordinator::with_models(config, models).with_mode(PipelineMode::Conversation);
    let cancel = pipeline.cancel_token();

    // Handle Ctrl+C
    let cancel_clone = cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            info!("received Ctrl+C, shutting down...");
            cancel_clone.cancel();
        }
    });

    // Suggest Metal acceleration on macOS when not compiled with it
    #[cfg(all(target_os = "macos", not(feature = "metal")))]
    println!("\nTip: Compile with --features metal for GPU acceleration on Apple Silicon");

    if gate_enabled {
        println!(
            "\nListening for \"{}\"... Say \"{}\" to stop. Press Ctrl+C to quit.\n",
            wake_word_display, stop_phrase_display,
        );
    } else {
        println!("\nReady! Speak into your microphone. Press Ctrl+C to stop.\n");
    }

    pipeline.run().await?;

    Ok(())
}

/// Capitalize the first character of a string.
fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => {
            let mut result = c.to_uppercase().to_string();
            result.push_str(chars.as_str());
            result
        }
        None => String::new(),
    }
}

fn list_devices() -> anyhow::Result<()> {
    println!("Input devices:");
    for name in CpalCapture::list_input_devices()? {
        println!("  - {name}");
    }

    println!("\nOutput devices:");
    for name in CpalPlayback::list_output_devices()? {
        println!("  - {name}");
    }

    Ok(())
}

async fn run_transcribe(config: SpeechConfig) -> anyhow::Result<()> {
    println!("Fae v{} - Transcription Mode", env!("CARGO_PKG_VERSION"));

    // Download & load only STT model
    let models = fae::startup::initialize_models(&config).await?;

    let pipeline =
        PipelineCoordinator::with_models(config, models).with_mode(PipelineMode::TranscribeOnly);
    let cancel = pipeline.cancel_token();

    let cancel_clone = cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            info!("received Ctrl+C, shutting down...");
            cancel_clone.cancel();
        }
    });

    println!("\nReady! Speak into your microphone. Press Ctrl+C to stop.\n");

    pipeline.run().await?;

    Ok(())
}
