import subprocess, time, json, urllib.request

BASE = "http://127.0.0.1:7433"
def api(path, data=None):
    req = urllib.request.Request(f"{BASE}{path}", json.dumps(data).encode() if data else None, {"Content-Type": "application/json"} if data else {}, method="POST" if data else "GET")
    return json.loads(urllib.request.urlopen(req, timeout=10).read())

def full_reset():
    try: api("/cancel")
    except: pass
    time.sleep(2)
    try: api("/reset")
    except: pass
    stable = 0
    for _ in range(15):
        time.sleep(2)
        try:
            c = api("/conversation")
            if c.get("count", 0) == 0 and not c.get("isGenerating") and not c.get("isSpeaking"):
                stable += 1
                if stable >= 2: return
            else: stable = 0
        except: pass

def speak_and_check(phrase, keywords):
    full_reset()
    subprocess.run(["voice", "-v", "am_adam", "-q", "-o", "/tmp/fae-eval.wav", phrase], capture_output=True, timeout=15)
    subprocess.run(["afplay", "/tmp/fae-eval.wav"], capture_output=True, timeout=10)
    for _ in range(25):
        time.sleep(1)
        try:
            c = api("/conversation")
            if c.get("count", 0) > 0:
                for m in reversed(c.get("messages", [])):
                    if m.get("role") == "user":
                        stt = m.get("content", "").lower()
                        return stt, all(k.lower() in stt for k in keywords)
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

print(f"\n=== STT ACCURACY: {p*100//len(tests)}% ({p}/{len(tests)}) ===")
