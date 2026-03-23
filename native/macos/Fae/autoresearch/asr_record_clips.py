# /// script
# requires-python = ">=3.11"
# dependencies = ["sounddevice", "soundfile", "numpy"]
# ///
"""Record audio clips for ASR accuracy evaluation.

Interactive tool: speaks a prompt, records your response, saves .wav + .txt pairs.

Usage:
    uv run autoresearch/asr_record_clips.py
    uv run autoresearch/asr_record_clips.py --output path/to/corpus
    uv run autoresearch/asr_record_clips.py --custom       # free-form recording
    uv run autoresearch/asr_record_clips.py --duration 5    # 5 second clips
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

SAMPLE_RATE = 16000
DEFAULT_DURATION = 4  # seconds

# Pre-built test phrases covering Fae's key scenarios
DEFAULT_PHRASES = [
    # Greetings
    ("greeting_01", "Hello Fae"),
    ("greeting_02", "Good morning"),
    ("greeting_03", "Hey there how are you"),
    # Commands
    ("command_01", "What time is it"),
    ("command_02", "Set a timer for five minutes"),
    ("command_03", "Search the web for weather forecast"),
    # Names (critical for DynamicVocabularyCorrector testing)
    ("name_01", "My name is David"),
    ("name_02", "Call Sarah"),
    ("name_03", "Send a message to James"),
    # Complex queries
    ("complex_01", "What is the capital of France"),
    ("complex_02", "Tell me about quantum computing"),
    ("complex_03", "How do I make pasta carbonara"),
    # Short utterances (edge case)
    ("short_01", "Yes"),
    ("short_02", "No thanks"),
    ("short_03", "Stop"),
    # Conversational (natural speech patterns)
    ("conv_01", "I was thinking about going to the store later"),
    ("conv_02", "Can you remind me to call the dentist tomorrow"),
    ("conv_03", "What did we talk about yesterday"),
    # Technical (domain-specific vocabulary)
    ("tech_01", "Open the terminal and run git status"),
    ("tech_02", "Check the pull request on GitHub"),
    # Numbers and spelling
    ("number_01", "The number is four one five two three six"),
    ("spell_01", "Spell it F A E"),
    # Noisy/casual (likely to challenge ASR)
    ("casual_01", "Um so yeah I was wondering if you could help me with something"),
    ("casual_02", "Okay so basically what happened was"),
]


def record_clip(duration: float) -> np.ndarray:
    """Record audio from the default microphone."""
    print(f"  Recording for {duration}s... ", end="", flush=True)
    audio = sd.rec(
        int(duration * SAMPLE_RATE),
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
    )
    sd.wait()
    print("done.")
    return audio.flatten()


def save_clip(audio: np.ndarray, output_dir: Path, name: str, text: str):
    """Save audio clip and ground truth transcription."""
    wav_path = output_dir / f"{name}.wav"
    txt_path = output_dir / f"{name}.txt"
    sf.write(str(wav_path), audio, SAMPLE_RATE)
    txt_path.write_text(text)
    print(f"  Saved: {wav_path.name} + {txt_path.name}")


def has_speech(audio: np.ndarray, threshold: float = 0.01) -> bool:
    """Simple check if recording contains speech (RMS above threshold)."""
    rms = np.sqrt(np.mean(audio**2))
    return rms > threshold


def main():
    parser = argparse.ArgumentParser(description="Record ASR test clips")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).parent / "asr_corpus",
        help="Output directory for clips (default: autoresearch/asr_corpus/)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=DEFAULT_DURATION,
        help=f"Recording duration in seconds (default: {DEFAULT_DURATION})",
    )
    parser.add_argument(
        "--custom",
        action="store_true",
        help="Free-form recording mode (type your own phrases)",
    )
    parser.add_argument(
        "--skip-existing",
        action="store_true",
        help="Skip clips that already have .wav files",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    print(f"Output directory: {args.output}")
    print(f"Recording duration: {args.duration}s per clip")
    print(f"Sample rate: {SAMPLE_RATE} Hz")
    print()

    if args.custom:
        print("FREE-FORM MODE: Type a phrase, then speak it when prompted.")
        print("Type 'q' or 'quit' to stop.\n")
        idx = 1
        while True:
            text = input(f"Phrase {idx} (or 'q' to quit): ").strip()
            if text.lower() in ("q", "quit", ""):
                break
            name = f"custom_{idx:03d}"
            print(f"\n  Say: \"{text}\"")
            input("  Press Enter when ready...")
            audio = record_clip(args.duration)
            if has_speech(audio):
                save_clip(audio, args.output, name, text)
                idx += 1
            else:
                print("  No speech detected, skipping.")
            print()
    else:
        print(f"GUIDED MODE: {len(DEFAULT_PHRASES)} pre-built phrases.")
        print("Press Enter to record each phrase. Type 's' to skip, 'q' to quit.\n")

        recorded = 0
        for name, text in DEFAULT_PHRASES:
            wav_path = args.output / f"{name}.wav"
            if args.skip_existing and wav_path.exists():
                print(f"  SKIP (exists): {name}")
                continue

            print(f"  [{name}] Say: \"{text}\"")
            choice = input("  Press Enter to record, 's' to skip, 'q' to quit: ").strip().lower()
            if choice == "q":
                break
            if choice == "s":
                print("  Skipped.\n")
                continue

            audio = record_clip(args.duration)
            if has_speech(audio):
                save_clip(audio, args.output, name, text)
                recorded += 1
            else:
                print("  No speech detected. Try again? (Enter=retry, s=skip)")
                retry = input("  ").strip().lower()
                if retry != "s":
                    audio = record_clip(args.duration)
                    if has_speech(audio):
                        save_clip(audio, args.output, name, text)
                        recorded += 1
            print()

        print(f"\nRecorded {recorded}/{len(DEFAULT_PHRASES)} clips to {args.output}")

    # Summary
    wav_count = len(list(args.output.glob("*.wav")))
    txt_count = len(list(args.output.glob("*.txt")))
    print(f"\nCorpus: {wav_count} audio files, {txt_count} transcription files")
    if wav_count != txt_count:
        print("  WARNING: mismatch between .wav and .txt counts")


if __name__ == "__main__":
    main()
