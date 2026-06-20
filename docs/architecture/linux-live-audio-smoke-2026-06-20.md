# Linux live mic + speaker smoke (P5 / D2-V5, Stage 5)

> **Status: DEFERRED — documentation only.** This is the one P5 step that needs a
> real Linux box with an audio device. Headless CI runners have no microphone or
> speaker, so the live mic→speaker turn cannot run there. The full voice spine is
> already proven headless in CI (clip → STT → LLM → Piper TTS → spoken WAV →
> Qwen3-ASR round-trip intelligibility gate; see `ci-linux.yml`). This page is the
> owner/real-hardware runbook for confirming the *device* legs on a Linux desktop.
> **The phase is NOT blocked on hardware we don't have.**

## Why this is a smoke, not a gate

Fae's audio I/O lives in `crates/fae-audio` (`AudioManager`). It is **portable by
construction**: the crate has **zero `#[cfg(target_os)]`** and uses
[`cpal`](https://crates.io/crates/cpal) `0.15` for capture and playback. The same
code that records the push-to-talk clip and plays TTS on macOS (CoreAudio) drives
**ALSA / PulseAudio / PipeWire on Linux** through cpal's host abstraction — no
Linux-specific audio code was written for P5. Capture (16 kHz mono WAV),
`play_wav`, and the non-blocking `play_start`/`play_stop` (with RMS level events)
are all backend-agnostic.

What CI *cannot* exercise is a physical input/output device. That is the only gap
this smoke closes, and it is an owner action on real Linux hardware.

## Audio backend on Linux

- cpal `0.15` uses the **ALSA** backend on Linux. The packaged `.deb` declares
  `libasound2` in its `Depends` (`scripts/build-linux-package.py`), and CI installs
  `libasound2-dev` to build. ALSA is the lowest common layer.
- **PulseAudio** and **PipeWire** both expose ALSA-compatible devices (PipeWire via
  `pipewire-alsa`, Pulse via its ALSA plugin), so cpal sees them as ALSA devices.
  On a modern desktop the default device is usually the Pulse/PipeWire server,
  which is what you want (it handles mixing and routing). No Fae change is needed
  to use any of the three — it is whatever ALSA resolves to on the host.
- If only bare ALSA is present (no sound server), cpal talks to the hardware
  device directly; pick it explicitly with the env vars below if the default is
  wrong (e.g. an HDMI sink with no speakers).

## Device selection (verified against `crates/fae-audio/src/lib.rs`)

Two environment variables override the device, falling back to the host default:

| Variable | Effect |
|----------|--------|
| `FAE_AUDIO_INPUT_DEVICE`  | Capture device. Case-insensitive **substring** match against cpal input device names; unset/empty → `host.default_input_device()`. |
| `FAE_AUDIO_OUTPUT_DEVICE` | Playback device. Same substring match against output device names; unset/empty → `host.default_output_device()`. |

- Matching is a `to_ascii_lowercase().contains(...)` substring test
  (`select_named_device`), so `FAE_AUDIO_OUTPUT_DEVICE=usb` matches a device named
  `"USB Audio Device"`. A non-matching name is a hard error
  (`"output device matching '…' not found"`) — it does **not** silently fall back,
  so a typo fails loudly.
- To see the exact names cpal reports, query the daemon's `audio.devices` command
  (returns `{ inputs, outputs, default_input, default_output }`) or list ALSA
  devices with `arecord -l` / `aplay -l` (and `pactl list short sinks` /
  `wpctl status` for Pulse / PipeWire).

## Prerequisites on the Linux desktop

1. A working sound stack: `libasound2` plus, typically, PulseAudio or PipeWire.
   Verify playback and capture independently first, outside Fae:
   ```bash
   speaker-test -t sine -f 440 -l 1     # you should hear a tone
   arecord -d 3 /tmp/mic-test.wav && aplay /tmp/mic-test.wav   # record + play back
   ```
   If those don't work, fix the OS audio setup before involving Fae.
2. The Fae daemon built natively for the target arch (`cargo build -p fae-daemon`),
   the SHA-pinned **Piper** runtime installed
   (`python3 scripts/install-piper-runtime.py --platform linux-x86_64`
   or `linux-aarch64`), the **llama.cpp** runtime installed, and `models.lock`
   present at `$XDG_DATA_HOME/fae/models.lock` (or `~/.local/share/fae/models.lock`).
   This is the same setup the `.deb` produces.

## Running the live turn

There is no special "live mode" — the live turn is the ordinary daemon path with a
real device attached. Two ways to drive it:

### A. Full app (preferred, once a Linux orb host exists — P6)

Launch the daemon + UI the way the platform ships it and use push-to-talk: speak,
release, hear Fae's spoken answer through the speaker. On Linux the capture/playback
go through cpal→ALSA automatically. Select non-default devices by exporting the env
vars before launch, e.g.:
```bash
export FAE_AUDIO_INPUT_DEVICE="USB"      # your mic, substring match
export FAE_AUDIO_OUTPUT_DEVICE="Speakers"
# …launch the daemon/app…
```

### B. Daemon socket commands (works today, no UI needed)

The daemon already exposes the live primitives over its NDJSON socket — these touch
the real device:

- `audio.capture_start` / `audio.capture_stop` — record a 16 kHz mono WAV from the
  input device (returns the clip), then feed it to the turn.
- `tts.speak` — synthesize via Piper and **play through the output device**
  (non-blocking; emits `audio.level` events and `audio.playback_ended`).
- `audio.play` — play a provided WAV through the output device.
- `audio.stop` — barge-in: drop the active playback stream immediately.

A minimal live loop: `audio.capture_start` → (speak) → `audio.capture_stop` → run
the turn (STT → LLM → Piper TTS) → `tts.speak` the answer → confirm you hear it.
This is the same chain the headless `--offline-turn` driver runs file-to-file in CI;
the only difference is a real mic in and a real speaker out.

## What "pass" looks like

- You speak into the mic, and the captured clip transcribes correctly (no device =
  no audio = empty clip, which is the failure to look for).
- Fae's answer plays through the speaker as **intelligible Piper speech** at a
  sensible volume, with no dropouts, and barge-in (`audio.stop` / starting a new
  capture) cuts playback promptly.
- Switching `FAE_AUDIO_INPUT_DEVICE` / `FAE_AUDIO_OUTPUT_DEVICE` routes to the named
  device; a bogus name fails loudly rather than going silent.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| No sound, no error | Default output is the wrong sink (e.g. HDMI). Set `FAE_AUDIO_OUTPUT_DEVICE` to your speakers' substring; confirm with `speaker-test`. |
| `output device matching '…' not found` | Your substring matched nothing. List names via `audio.devices` / `aplay -l` and use a real fragment. |
| Empty/silent captured clip | No/!default input device, or another app holds the mic exclusively (bare-ALSA `hw:` is exclusive). Prefer the Pulse/PipeWire default device, or close the other app. |
| Choppy playback / xruns | ALSA buffer underruns under load — usually a Pulse/PipeWire latency setting, not Fae. Run via the sound server rather than raw `hw:`. |
| Works in `aplay` but not Fae | Confirm `libasound2` is installed and the daemon isn't pinned to a stale device name via the env vars. |

## Scope notes

- **Speaker-ID stays dropped** (voice identity retired, S18) — there is no
  enrollment or recognition leg to smoke here, only capture + playback.
- The **macOS V5 capture flip** (Swift AVAudioEngine → daemon cpal) is explicitly
  out of scope for P5; this page is Linux-only.
- This smoke is owner-run on real hardware and is intentionally **not** wired into
  CI. The portable cpal code + the headless intelligibility gate are the automated
  proofs; this runbook is the manual confirmation of the device legs.
