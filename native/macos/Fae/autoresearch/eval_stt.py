import subprocess, time, json, urllib.request

BASE = "http://127.0.0.1:7433"
def api(path, data=None):
    req = urllib.request.Request(f"{BASE}{path}", json.dumps(data).encode() if data else None, {"Content-Type": "application/json"} if data else {}, method="POST" if data else "GET")
    return json.loads(urllib.request.urlopen(req, timeout=10).read())

def speak_and_check(phrase, keywords):
    """Speak phrase, wait for a NEW user message, check keywords."""
    # Cancel any ongoing generation and note current message count
    try: api("/cancel")
    except: pass
    time.sleep(1)

    pre_count = 0
    try: pre_count = api("/conversation").get("count", 0)
    except: pass

    # Wait for silence (no generation, no speaking)
    for _ in range(20):
        time.sleep(1)
        try:
            c = api("/conversation")
            if not c.get("isGenerating") and not c.get("isSpeaking"):
                break
        except: pass

    # Extra wait for echo tail clearance
    time.sleep(5)

    # Record the timestamp BEFORE speaking
    speak_time = time.time()

    subprocess.run(["voice", "-v", "am_adam", "-q", "-o", "/tmp/fae-eval.wav", phrase], capture_output=True, timeout=15)
    subprocess.run(["afplay", "/tmp/fae-eval.wav"], capture_output=True, timeout=10)

    # Wait for a NEW user message (count > pre_count)
    for _ in range(25):
        time.sleep(1)
        try:
            c = api("/conversation")
            if c.get("count", 0) > pre_count:
                msgs = c.get("messages", [])
                # Find the NEWEST user message
                for m in reversed(msgs):
                    if m.get("role") == "user":
                        ts = m.get("timestamp", 0)
                        stt = m.get("content", "").lower()
                        # Only accept if this message is newer than our speak time
                        if ts > speak_time - 5:  # 5s tolerance
                            return stt, all(k.lower() in stt for k in keywords)
                        else:
                            # Stale message — keep waiting
                            break
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
]

p = 0
for phrase, kw in tests:
    stt, ok = speak_and_check(phrase, kw)
    p += ok
    print(f"[{'PASS' if ok else 'FAIL'}] '{phrase}' → '{stt}'")

score = p * 100 // len(tests)
print(f"\n=== STT ACCURACY: {score}% ({p}/{len(tests)}) ===")

# Append to results log
with open("autoresearch/results.tsv", "a") as f:
    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())}\t{score}\tstt_accuracy\t{len(tests)}_tests\tv0.8.164\n")
