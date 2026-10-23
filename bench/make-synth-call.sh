#!/bin/bash
# T08 PROVISIONAL replay call from the synth TTS clips (not a real call; real calls = T02a).
# Writes bench/calls/call-01.wav (THEM: 20 Arabic clips), call-01.me.wav (ME: 10 English clips) on one
# timeline (one speaker at a time, 2.5 s silence after each turn), and call-01.labels.json in the
# CallLabels format (mac/Sources/HamsaKit/STT/CallLabels.swift). All three are gitignored.
# Usage: bench/make-synth-set.sh && bench/make-synth-call.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p calls
python3 -I - "$PWD" <<'EOF'
import json, sys, wave, os
root = sys.argv[1]
RATE, GAP, LEAD = 16000, 2.5, 0.5
# Question / tech flags by clip number (see make-synth-set.sh sentence lists).
AR_Q = {2, 4, 5, 7, 10, 13, 16, 18, 20}; AR_TECH = {10, 20}
EN_Q = {1, 3, 5, 8, 10}; EN_TECH = {5, 8}

def clip(lang, n):
    base = os.path.join(root, "synth", lang, "%02d" % n)
    with wave.open(base + ".wav") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, base
        pcm = w.readframes(w.getnframes())
    return pcm, open(base + ".txt", encoding="utf-8").read().strip()

turns = []
for i in range(1, 21):
    turns.append(("them", "ar", i))
    if i % 2 == 0: turns.append(("me", "en", i // 2))
tracks = {"them": bytearray(), "me": bytearray()}
silence = lambda s: b"\0\0" * int(s * RATE)
for t in tracks.values(): t += silence(LEAD)
items = []
for ch, lang, n in turns:
    pcm, text = clip(lang, n)
    start = len(tracks[ch]) / 2 / RATE
    other = "me" if ch == "them" else "them"
    tracks[ch] += pcm; tracks[other] += silence(len(pcm) / 2 / RATE)
    end = len(tracks[ch]) / 2 / RATE
    q = (lang == "ar" and n in AR_Q) or (lang == "en" and n in EN_Q)
    tech = (lang == "ar" and n in AR_TECH) or (lang == "en" and n in EN_TECH)
    items.append(dict(channel=ch, start=round(start, 3), end=round(end, 3), text=text, is_question=q,
                      tech=tech, verbatim=True, lang=lang))
    for t in tracks.values(): t += silence(GAP)
names = {"them": "call-01.wav", "me": "call-01.me.wav"}
for ch, data in tracks.items():
    with wave.open(os.path.join(root, "calls", names[ch]), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(bytes(data))
with open(os.path.join(root, "calls", "call-01.labels.json"), "w", encoding="utf-8") as f:
    json.dump(dict(audio=names, provisional=True, items=items), f, ensure_ascii=False, indent=1)
print("call-01: %.1f s, %d items, %d questions" % (len(tracks["them"]) / 2 / RATE, len(items), sum(i["is_question"] for i in items)))
EOF
