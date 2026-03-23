# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile", "numpy"]
# ///
"""Generate a synthetic ASR test corpus using macOS 'say' command.

Creates .wav + .txt pairs for immediate use with asr_accuracy_eval.py.
Uses macOS built-in TTS to generate audio — not perfect speech but good
enough for a quick baseline comparison. For real evaluation, use
asr_record_clips.py to record your own voice.

Usage:
    uv run autoresearch/asr_generate_corpus.py
    uv run autoresearch/asr_generate_corpus.py --voice Samantha
    uv run autoresearch/asr_generate_corpus.py --output path/to/corpus
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

# Test phrases covering Fae's key scenarios
PHRASES = [
    # Greetings
    ("greeting_01", "Hello Fae"),
    ("greeting_02", "Good morning"),
    ("greeting_03", "Hey there how are you"),
    # Commands
    ("command_01", "What time is it"),
    ("command_02", "Set a timer for five minutes"),
    ("command_03", "Search the web for weather forecast"),
    # Names
    ("name_01", "My name is David"),
    ("name_02", "Call Sarah"),
    ("name_03", "Send a message to James"),
    # Questions
    ("question_01", "What is the capital of France"),
    ("question_02", "Tell me about quantum computing"),
    ("question_03", "How do I make pasta carbonara"),
    # Short utterances
    ("short_01", "Yes"),
    ("short_02", "No thanks"),
    ("short_03", "Stop"),
    # Conversational
    ("conv_01", "I was thinking about going to the store later"),
    ("conv_02", "Can you remind me to call the dentist tomorrow"),
    ("conv_03", "What did we talk about yesterday"),
    # Technical
    ("tech_01", "Open the terminal and run git status"),
    ("tech_02", "Check the pull request on GitHub"),
    # Numbers
    ("number_01", "The number is four one five two three six"),
    ("spell_01", "Spell it F A E"),
    # Casual / challenging
    ("casual_01", "So yeah I was wondering if you could help me with something"),
    ("casual_02", "Okay so basically what happened was"),
]


def generate_clip(text: str, output_wav: Path, voice: str = "Samantha", rate: int = 180):
    """Generate a .wav clip using macOS 'say' command."""
    with tempfile.NamedTemporaryFile(suffix=".aiff", delete=True) as tmp:
        tmp_path = tmp.name
        # macOS 'say' outputs AIFF
        result = subprocess.run(
            ["say", "-v", voice, "-r", str(rate), "-o", tmp_path, text],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"  ERROR: say command failed: {result.stderr}")
            return False

        # Convert to 16kHz mono WAV
        data, sr = sf.read(tmp_path, dtype="float32")
        if len(data.shape) > 1:
            data = data.mean(axis=1)  # stereo to mono

        # Resample to 16kHz
        if sr != 16000:
            ratio = 16000 / sr
            new_len = int(len(data) * ratio)
            indices = np.linspace(0, len(data) - 1, new_len)
            data = np.interp(indices, np.arange(len(data)), data).astype(np.float32)

        sf.write(str(output_wav), data, 16000)
        return True


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic ASR test corpus")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).parent / "asr_corpus",
        help="Output directory (default: autoresearch/asr_corpus/)",
    )
    parser.add_argument(
        "--voice",
        default="Samantha",
        help="macOS TTS voice (default: Samantha). Try: say -v '?'",
    )
    parser.add_argument(
        "--rate",
        type=int,
        default=180,
        help="Speech rate in words per minute (default: 180)",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    print(f"Generating {len(PHRASES)} clips using voice '{args.voice}'...")
    print(f"Output: {args.output}\n")

    generated = 0
    for name, text in PHRASES:
        wav_path = args.output / f"{name}.wav"
        txt_path = args.output / f"{name}.txt"

        print(f"  {name}: \"{text}\"")
        if generate_clip(text, wav_path, voice=args.voice, rate=args.rate):
            txt_path.write_text(text)
            generated += 1
        else:
            print(f"    FAILED")

    print(f"\nGenerated {generated}/{len(PHRASES)} clips")
    print(f"\nRun the eval:")
    print(f"  uv run autoresearch/asr_accuracy_eval.py --corpus {args.output}")


if __name__ == "__main__":
    main()
