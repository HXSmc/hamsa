# 07 Engineering Plan — Hamsa

> Draft v1, 2026-10-22. Build order: Spikes (go/no-go) → Brain → Mac live path → Mac app → Gate.
> **Where it runs**: `[mini]` = this mini PC; `[mac]` = MacBook (Swift/Xcode). Mac tasks run in a
> Claude session started on the Mac (CLAUDE.md cross-device rule), never "owner, please run".

## Repo layout (file ownership roots)
```
mac/      Swift package: HamsaKit (lib), hamsa-cli, hamsa-bench, Hamsa.app (XcodeGen project.yml)
brain/    Python 3.12 uv project: hamsa_brain/ (indexer, cards, summarize, learn, api)
bench/    test sets: ar-sa/ (clips + ref transcripts), questions.jsonl, calls/ (replay WAVs) — gitignored audio
docs/     kickoff docs + adr/
```

## Build-vs-buy
| Need | Take | Build |
|---|---|---|
| System audio | AudioCap (BSD-2) process-tap pattern | thin `AudioCapture` wrapper |
| VAD, STT | FluidAudio / WhisperKit (or Apple SpeechTranscriber) per T02 | streaming glue only |
| Vector search | sqlite-vec | — |
| Summary prompt | Meetily templates (MIT, credit in file header) | vault writer |
| LLM | Groq / Gemini free APIs | provider chain + cancel |
| **Differentiator** | — | card prediction, question detector, tiered overlay, learning loop |

## Tasks
Each task: owner dir · depends on · acceptance command (must pass with real output).

**Phase 0 — Spikes (if T02 or T03 fails, stop and re-plan)**
- **T01 [mini] Scaffold** · all roots · — · `test -f mac/Package.swift && cd brain && uv run pytest -q` → `1 passed` (smoke test).
- **T02 [mac] STT benchmark** · `mac/Sources/hamsa-bench/Wer*`, `bench/ar-sa/` · T01 · owner records 20 clips (founder-gated) ·
  `swift run hamsa-bench wer --set bench/ar-sa --engine all` → table per engine; winner has `WER<=0.25 partial_p50_ms<=500 rss_mb<=900`. Writes `docs/adr/001-stt.md`.
- **T03 [mac] LLM probe** · `mac/Sources/hamsa-bench/Llm*` · T01 · `swift run hamsa-bench llm --n 50 --providers groq,gemini` → `ttft_p50_ms<=600` for ≥ 1 provider + 10 Saudi-Arabic answers saved to `bench/llm-ar.md` for owner judgment. Writes `docs/adr/002-llm.md`.
- **T04 [mac] Capture** · `mac/Sources/HamsaKit/Audio/` · T01 · `swift run hamsa-cli capture --seconds 10 --out /tmp/cap` → `them.wav me.wav` both `rms_dbfs>-50`.

**Phase 1 — Brain (mini PC)**
- **T05 Indexer** · `brain/hamsa_brain/index/` · T01 · `uv run hamsa-brain index refresh --project taweed && uv run hamsa-brain eval retrieval --set ../bench/questions.jsonl` → `recall@5>=0.80` (gold set: 20 Q, 10 ar + 10 en, written from Taweed docs). Excludes `Secrets/` (test asserts it).
- **T06 Card generator** · `brain/hamsa_brain/cards/` · T05 · `uv run hamsa-brain cards build --project taweed && uv run hamsa-brain cards stats --project taweed` → `cards>=50 bilingual=100% sources=100%`; pytest rejects unsourced card.
- **T07 Brain API + service** · `brain/hamsa_brain/api/`, `brain/deploy/hamsa-brain.service` · T06 · `systemctl --user is-active hamsa-brain` → `active`; `curl -s -H "Authorization: Bearer $(cat ~/.config/hamsa/token)" http://<tailscale-ip>:8765/healthz` → `{"ok":true}`; same curl without token → `401`.

**Phase 2 — Mac live path**
- **T08 Streaming STT + live.sqlite** · `mac/Sources/HamsaKit/STT/`, `.../Store/` · T02,T04 · `swift run hamsa-cli transcribe --replay bench/calls/taweed-01.wav` → segments with `channel`, `lang`, partials every ≤ 500 ms; `swift test --filter STT` passes.
- **T09 Question detector** · `.../Detect/` · T08 · `swift test --filter Detect` → precision ≥ 0.85, recall ≥ 0.80 on `bench/questions-detect.jsonl` (ar + en, incl. Saudi forms: وش، ليش، كيف، هل، متى، كم).
- **T10 T0/T1 matcher** · `.../Retrieve/` · T05,T06,T09 · `swift run hamsa-bench match --set bench/questions.jsonl` → `t0_p50_ms<=100 t1_p50_ms<=150 top1_card_acc>=0.8`. Note: system SQLite blocks extensions → bundle SQLite + sqlite-vec statically (GRDB custom build or C target).
- **T11 T2 streaming client** · `.../LLM/` · T03,T10 · `swift run hamsa-bench llm --n 50 --with-context` → `ttft_p50_ms<=600 cancel_ok=100% errors=0`; fallback test with Groq key removed → Gemini used.

**Phase 3 — Mac app**
- **T12 Overlay** · `mac/App/Overlay/` · T10,T11 · `swift run hamsa-bench latency --replay bench/calls/taweed-01.wav --ui` → `first_text_p50_ms<=800`; screenshot of RTL Arabic card; Zoom screen-share test shows overlay hidden (screenshot evidence).
- **T13 Menu bar + onboarding + prepare/start/stop** · `mac/App/Shell/` · T07,T12 · launch `Hamsa.app`, complete onboarding, Prepare → "Ready: N cards"; evidence via `jarvis-screen frame`.
- **T14 Summary** · `brain/hamsa_brain/summarize/` · T07,T08 · `uv run hamsa-brain summarize --meeting <id>` → vault note with Summary / Decisions / Action items / Open questions; ≤ 120 s for a 60 min call.
- **T15 Learning loop + review** · `brain/hamsa_brain/learn/`, `mac/App/Review/` · T14 · `uv run hamsa-brain learn --meeting <id>` → `pending_review` +N; accepting one in ReviewQuestionsView makes it `active` after sync.

**Phase 4 — Gate**
- **T16 Pre-launch security gate** · read-only · all · run audit-workflow items 2 (security), 3 (API auth), 11 (production readiness): brain bound to Tailscale IP only, token required, no secrets in index, Keychain for keys, logs carry no transcript text.
- **T17 Launch criteria (3 real calls)** · — · T16 · owner uses Hamsa on 3 calls; `hamsa-bench report --last 3` prints KPIs from 01-prd.

## Launch criteria
Must work: capture both channels · Arabic + English transcript · cards shown for predicted Qs ·
"Not in your notes" instead of guesses · summary in vault · overlay hidden from screen share · nothing
leaves owned devices except T2 question + snippets.
Can be ugly: settings screen · review UI · onboarding polish.
The one thing to test on the first calls: **did the overlay answer arrive before the owner needed to speak?**

## Dependencies
T01 → T02,T03,T04,T05 (parallel) · T05→T06→T07 · T02+T04→T08→T09 · T05+T06+T09→T10→T11→T12 → T13 · T07+T08→T14→T15 · all→T16→T17.
