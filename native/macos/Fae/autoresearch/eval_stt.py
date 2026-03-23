"""Automated eval for Fae via audio injection (production-like).

Uses the test server's audio injection endpoint which bypasses the mic
but goes through the full STT pipeline (VAD, speaker ID, ASR, corrections).

For real speaker testing, use the manual test: voice + afplay.

Run from native/macos/Fae: python3 autoresearch/eval_stt.py
"""
import subprocess, time, json, urllib.request, os, tempfile

BASE = "http://127.0.0.1:7433"
def api(path, data=None):
    req = urllib.request.Request(f"{BASE}{path}", json.dumps(data).encode() if data else None, {"Content-Type": "application/json"} if data else {}, method="POST" if data else "GET")
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def inject_audio_and_check(phrase, keywords, timeout=60):
    """Generate TTS audio, inject via test server, check STT output."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_path = f.name
    raw_path = wav_path.replace(".wav", "_raw.wav")

    # Generate speech with Kokoro
    subprocess.run(["voice", "-v", "am_adam", "-q", "-o", raw_path, phrase], capture_output=True, timeout=15)
    # Convert to 16kHz mono
    subprocess.run(["ffmpeg", "-y", "-i", raw_path, "-ar", "16000", "-ac", "1", wav_path], capture_output=True, timeout=10)

    try: os.unlink(raw_path)
    except: pass

    # Cancel any ongoing work and wait for full idle
    try: api("/cancel")
    except: pass
    for _ in range(20):
        time.sleep(1)
        try:
            c = api("/conversation")
            if not c.get("isGenerating") and not c.get("isSpeaking"):
                break
        except: pass
    time.sleep(2)

    pre_count = api("/conversation").get("count", 0)

    # Inject audio
    api("/command", {"name": "test.inject_audio", "payload": {"path": wav_path}})

    # Wait for response
    for _ in range(timeout):
        time.sleep(1)
        c = api("/conversation")
        count = c.get("count", 0)
        if count >= pre_count + 2:  # user msg + assistant msg
            # Find the user message
            for m in c.get("messages", []):
                if m.get("role") == "user":
                    last_user = m
            stt = last_user.get("content", "").lower() if last_user else ""
            try: os.unlink(wav_path)
            except: pass
            return stt, all(k.lower() in stt for k in keywords)
        if not c.get("isGenerating") and count > pre_count:
            for m in reversed(c.get("messages", [])):
                if m.get("role") == "user":
                    stt = m.get("content", "").lower()
                    try: os.unlink(wav_path)
                    except: pass
                    return stt, all(k.lower() in stt for k in keywords)

    try: os.unlink(wav_path)
    except: pass
    return "", False

tests = [
    ("Fae, check my calendar", ["check", "calendar"]),
    ("Fae, what is my name", ["what", "name"]),
    ("Fae, tell me a joke", ["tell", "joke"]),
    ("Fae, remind me to buy milk", ["remind", "milk"]),
    ("Hey Fae, good morning", ["good", "morning"]),
    ("Fae, who am I", ["who"]),
    ("Fae, search the web for news", ["search", "news"]),
    ("Fae, remember my birthday is in June", ["birthday", "june"]),
    ("Fae, what football team do I support", ["football"]),
    ("Fae, set your speed to 1.2", ["speed", "1.2"]),
]

p = 0
for phrase, kw in tests:
    stt, ok = inject_audio_and_check(phrase, kw, timeout=45)
    p += ok
    print(f"[{'PASS' if ok else 'FAIL'}] '{phrase}' → '{stt}'")

score = p * 100 // len(tests)
print(f"\n=== STT ACCURACY: {score}% ({p}/{len(tests)}) ===")

with open("autoresearch/results.tsv", "a") as f:
    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())}\t{score}\tstt_accuracy\t{len(tests)}_tests\taudio_injection\n")
