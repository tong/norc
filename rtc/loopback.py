#!/usr/bin/env python3
"""
Tests norc-rtc without XMPP: starts a caller and a callee and passes their messages to each other, as norc does
over Jingle. Succeeds when both are connected and receive the media of the other.

	rtc/loopback.py [--video] [--real] [--seconds N] [NORC_RTC]

--real uses the microphone and speaker (and camera) instead of test signals: you hear yourself.
"""
import json, subprocess, sys, threading, time

args = sys.argv[1:]
video = "--video" in args
real = "--real" in args
seconds = float(args[args.index("--seconds") + 1]) if "--seconds" in args else 5
paths = [a for a in args if not a.startswith("--") and not a.replace(".", "").isdigit()]
binary = paths[0] if paths else "./norc-rtc"
options = (["--video"] if video else []) + ([] if real else ["--test"])

procs = {n: subprocess.Popen([binary] + options, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) for n in ("caller", "callee")}
peer = {"caller": "callee", "callee": "caller"}
seen = {n: set() for n in procs}
lock = threading.Lock()

def send(name, msg):
	with lock:
		procs[name].stdin.write(json.dumps(msg) + "\n")
		procs[name].stdin.flush()

def relay(name):
	for line in procs[name].stdout:
		msg = json.loads(line)
		t = msg["type"]
		print(f"{name:6} {t}: " + ", ".join(f"{k}={str(v)[:60]!r}" for k, v in msg.items() if k != "type"), flush=True)
		if t in ("sdp", "candidate"):
			send(peer[name], msg)
		elif t == "ready" and name == "caller":
			send(name, {"type": "offer"})
		seen[name].add(f"{t}:{msg.get('state') or msg.get('media') or ''}")

threads = [threading.Thread(target=relay, args=(n,), daemon=True) for n in procs]
for t in threads:
	t.start()

wanted = {"state:connected", "media:audio"} | ({"media:video"} if video else set())
end = time.time() + 20
while time.time() < end and not all(wanted <= s for s in seen.values()):
	time.sleep(0.1)
ok = all(wanted <= s for s in seen.values())
if ok and seconds > 0:
	time.sleep(seconds)
for n in procs:
	send(n, {"type": "hangup"})
codes = {n: p.wait(10) for n, p in procs.items()}
for t in threads:
	t.join(2)
print("ok" if ok else f"failed: caller {sorted(seen['caller'])}, callee {sorted(seen['callee'])}", "exit codes", codes)
sys.exit(0 if ok and not any(codes.values()) else 1)
