#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "kokoro-onnx",
#   "numpy",
#   "onnxruntime",
# ]
# ///
"""
Kokoro ONNX TTS server — runs as a child process owned by KokoroPythonTTSEngine.

Protocol (all I/O is binary on stdin/stdout):
  Request:  JSON line terminated by newline written to stdin
            {"text": "...", "voice": "af_heart", "speed": 1.0}
  Response: One or more PCM chunks, each prefixed by a 4-byte little-endian int32
            indicating the number of float32 samples in the chunk.
            A final sentinel chunk with length = 0 signals end-of-utterance.
            On error, a chunk with length = -1 followed by a UTF-8 error message
            (4-byte length prefix + bytes) is sent.

Sample rate is always 24000 Hz, mono float32 in range [-1.0, 1.0].

The server logs diagnostics to stderr (visible in Xcode console / NSLog).
"""

import json
import os
import struct
import sys
import time
import traceback
import numpy as np
import onnxruntime as rt

# Lazy import of espeak-based tokenizer — only used for phonemization.
# kokoro-onnx bundles espeakng_loader so no system espeak needed.
from kokoro_onnx.tokenizer import Tokenizer

SAMPLE_RATE = 24_000
# Maximum tokens per ONNX forward pass (Kokoro architectural limit).
MAX_TOKENS = 510


def log(msg: str) -> None:
    """Write diagnostic message to stderr (captured by Swift NSLog)."""
    print(f"[kokoro_tts] {msg}", file=sys.stderr, flush=True)


def find_model() -> tuple[str, str]:
    """
    Locate the Kokoro ONNX model and voices directory.

    Search order:
    1. FAE_KOKORO_MODEL_PATH / FAE_KOKORO_VOICES_DIR environment variables
       (set by KokoroPythonTTSEngine with the Fae app-support path)
    2. HuggingFace cache (onnx-community/Kokoro-82M-v1.0-ONNX)
    """
    model_path = os.environ.get("FAE_KOKORO_MODEL_PATH")
    voices_dir = os.environ.get("FAE_KOKORO_VOICES_DIR")
    if model_path and voices_dir and os.path.exists(model_path) and os.path.isdir(voices_dir):
        return model_path, voices_dir

    hf_cache = os.path.expanduser(
        "~/.cache/huggingface/hub/models--onnx-community--Kokoro-82M-v1.0-ONNX/snapshots"
    )
    if os.path.isdir(hf_cache):
        for snap in sorted(os.listdir(hf_cache), reverse=True):
            snap_path = os.path.join(hf_cache, snap)
            m = os.path.join(snap_path, "onnx", "model_quantized.onnx")
            v = os.path.join(snap_path, "voices")
            if os.path.exists(m) and os.path.isdir(v):
                return m, v

    raise FileNotFoundError(
        "Kokoro ONNX model not found. "
        "Download: huggingface-cli download onnx-community/Kokoro-82M-v1.0-ONNX"
    )


def load_voices(voices_dir: str) -> dict[str, np.ndarray]:
    """
    Load individual voice .bin files (raw float32, shape [510, 1, 256])
    from the voices_dir.  Returns a dict mapping voice name → array.
    """
    voices: dict[str, np.ndarray] = {}
    for fname in sorted(os.listdir(voices_dir)):
        if not fname.endswith(".bin"):
            continue
        name = fname[: -len(".bin")]
        blob_path = os.path.realpath(os.path.join(voices_dir, fname))
        data = open(blob_path, "rb").read()
        arr = np.frombuffer(data, dtype=np.float32).reshape(510, 1, 256)
        voices[name] = arr
    return voices


def get_style(voices: dict[str, np.ndarray], voice_name: str, token_count: int) -> np.ndarray:
    """
    Select a [1, 256] style vector for the given token count from a voice.

    We sample the style vector at the position proportional to the length
    of the utterance (clamped to [0, 509]) — this mimics how the original
    Kokoro model was trained with length-conditional styles.
    """
    arr = voices.get(voice_name)
    if arr is None:
        arr = next(iter(voices.values()))
    idx = min(token_count, 509)
    return arr[idx]  # shape [1, 256]


def split_tokens(token_ids: list[int], max_tokens: int = MAX_TOKENS) -> list[list[int]]:
    """Split a long token sequence into chunks of at most max_tokens."""
    return [token_ids[i : i + max_tokens] for i in range(0, len(token_ids), max_tokens)]


def write_chunk(samples: np.ndarray) -> None:
    """Write a PCM chunk: [4-byte int32 length][float32 data]."""
    n = len(samples)
    sys.stdout.buffer.write(struct.pack("<i", n))
    sys.stdout.buffer.write(samples.astype(np.float32).tobytes())
    sys.stdout.buffer.flush()


def write_sentinel() -> None:
    """Write end-of-utterance sentinel (length = 0)."""
    sys.stdout.buffer.write(struct.pack("<i", 0))
    sys.stdout.buffer.flush()


def write_error(msg: str) -> None:
    """Write error marker: length = -1, then 4-byte string length, then UTF-8 bytes."""
    encoded = msg.encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<i", -1))
    sys.stdout.buffer.write(struct.pack("<i", len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def main() -> None:
    log("Starting Kokoro TTS server")

    try:
        model_path, voices_dir = find_model()
        log(f"Model: {model_path}")
        log(f"Voices dir: {voices_dir}")
    except FileNotFoundError as e:
        log(f"FATAL: {e}")
        sys.exit(1)

    log("Loading ONNX session...")
    t0 = time.time()
    sess = rt.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    log(f"ONNX session loaded in {time.time()-t0:.2f}s")

    log("Loading voices...")
    voices = load_voices(voices_dir)
    log(f"Loaded voices: {list(voices.keys())}")

    log("Loading tokenizer (espeak-ng)...")
    tokenizer = Tokenizer()
    log("Tokenizer ready")

    # Write a binary "ready" sentinel so Swift knows startup is complete.
    # Protocol: sentinel = [int32 = -2] (distinguishable from error = -1).
    sys.stdout.buffer.write(struct.pack("<i", -2))
    sys.stdout.buffer.flush()
    log("Server ready — waiting for requests")

    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue

        try:
            req = json.loads(raw_line)
        except json.JSONDecodeError as e:
            log(f"Bad JSON request: {e}")
            write_error(f"JSON parse error: {e}")
            continue

        text: str = req.get("text", "")
        voice_name: str = req.get("voice", "af_heart")
        speed: float = float(req.get("speed", 1.0))
        lang: str = req.get("lang", "en-us")

        if not text.strip():
            write_sentinel()
            continue

        t_start = time.time()
        try:
            # Phonemize → tokenize
            phonemes = tokenizer.phonemize(text, lang)
            token_ids = tokenizer.tokenize(phonemes)
            log(f"Text={repr(text[:60])} tokens={len(token_ids)} voice={voice_name} speed={speed}")

            # Split into chunks if needed
            chunks = split_tokens(token_ids)
            total_samples = 0
            for chunk_ids in chunks:
                input_ids = np.array([chunk_ids], dtype=np.int64)
                style = get_style(voices, voice_name, len(chunk_ids))
                speed_arr = np.array([speed], dtype=np.float32)

                waveform = sess.run(
                    None,
                    {
                        "input_ids": input_ids,
                        "style": style,
                        "speed": speed_arr,
                    },
                )[0]  # [1, num_samples]

                samples = waveform[0]  # [num_samples]
                write_chunk(samples)
                total_samples += len(samples)

            write_sentinel()
            duration = total_samples / SAMPLE_RATE
            elapsed = time.time() - t_start
            rtf = elapsed / duration if duration > 0 else 0
            log(f"Synthesized {duration:.2f}s audio in {elapsed:.3f}s (RTF={rtf:.2f})")

        except Exception as e:
            log(f"Synthesis error: {e}\n{traceback.format_exc()}")
            write_error(str(e))


if __name__ == "__main__":
    main()
