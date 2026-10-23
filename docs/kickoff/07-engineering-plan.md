# 07 Engineering Plan — Hamsa

> Draft v3, 2026-10-22. Expert validation: 2 rounds (REVISE → REVISE), all 18 edits applied; round cap hit, no further validator pass. Residual risk: Arabic STT lag + e5 dialect retrieval are unproven until T02 / T05b.
> Build order: Env + corpus → Spikes (go/no-go) → Brain → Mac live path → Mac app → Gate.
> **Where it runs**: `[mini]` = this mini PC; `[mac]` = MacBook (Swift/Xcode). The mini PC cannot build
> Swift. `[mac]` tasks run in a Claude session the hub starts on the Mac (CLAUDE.md cross-device rule:
> `jarvis-screen open Terminal` → `cd ~/work/hamsa && claude`), working in a clone of the same repo;
> it commits and pushes to a `mac/<task>` branch, and the mini PC pulls.

## Repo layout (file ownership roots)
```
mac/      Swift package (Package.swift owned by T01 only)
            HamsaKit (lib: Audio/ STT/ Detect/ Retrieve/ LLM/ Store/ Sync/)
            HamsaBench (shared bench code, T01)
            targets: hamsa-cli, bench-wer, bench-llm, bench-match, bench-latency, bench-soak, bench-report, bench-label
            App/ (XcodeGen project.yml → Hamsa.app)
brain/    Python 3.12 uv project: hamsa_brain/ (schema/, index/, cards/, summarize/, learn/, api/)
bench/    ar-sa/ (clips + ref .txt), calls/ (WAV + .labels.json), questions.jsonl, questions-detect.jsonl — audio gitignored
docs/     kickoff/ + adr/
```
Rule: T01 creates every target. Each target has ONE owner task: bench-wer=T02, bench-llm=T03, bench-match=T05b
(T10a/T10b add their own files under `Sources/bench-match/`), bench-latency=T12, bench-report=T02a (later tasks add
subcommands as separate files), bench-label=T02a, bench-soak=T12b, hamsa-cli=T04 (subcommands one file each:
`Capture.swift`, `PanelTest.swift`, `Sync.swift`, `Transcribe.swift`, `Live.swift`, registered in `Commands.swift` owned by T01).

## Build-vs-buy
| Need | Take | Build |
|---|---|---|
| System audio | AudioCap (BSD-2) process-tap pattern | `AudioCapture` (global tap minus Hamsa) |
| VAD, STT | FluidAudio / WhisperKit / Apple SpeechTranscriber per T02 | chunked-window glue |
| Vector search | sqlite-vec on brain; in-memory dot product on Mac | — |
| Summary prompt | Meetily templates (MIT, credit in file header) | vault writer |
| LLM | Groq / Gemini free APIs | provider chain + cancel |
| **Differentiator** | — | card prediction, question detector, tiered overlay, learning loop |

## Tasks
Format: owner dir · depends on · acceptance (real output required).

**Phase 0 — Environment, corpus, spikes (any spike fail → its Plan B in 03-tdd, then re-scope)**
- **T00 [mac] Env check** · `docs/adr/000-env.md` · — · `sw_vers; xcodebuild -version; security find-identity -v -p codesigning` → fail if macOS < 14.4, no Xcode, or no stable signing identity; if macOS ≥ 26, also report `SpeechTranscriber.supportedLocales` contains `ar_SA` and whether its asset downloads.
- **T01 [mini] Scaffold** · all roots · — · `test -f mac/Package.swift && (cd brain && uv run pytest -q)` → `1 passed`; Mac session later: `swift build` → `Build complete!`.
- **T02a [owner + mac] Corpus** · `bench/`, `Sources/bench-label/`, `Sources/bench-report/` · T01, T04 · owner (headphones on) records 5 calls with `hamsa-cli capture` (real calls only after the consent line was pasted in chat; otherwise staged calls with a second account) + 20 clips of 30–60 s; `bench-label` (simple CLI: play audio, key press marks question end, type question text, tag `tech:true`) produces `*.labels.json` and `questions-detect.jsonl` (≥ 150 lines counting ALL questions on THEM/ME, ≥ 50% ar-sa, `tech>=40`). Split by call: calls 1–3 = tune, calls 4–5 = test. Acceptance: `swift run bench-report corpus` → `calls=5 clips=20 labelled_questions>=150 tech>=40`. **Critical path; target date 2026-11-01.**
- **T02 [mac] STT benchmark** · `mac/Sources/bench-wer/`, `HamsaKit/STT/Bench*` · T00, T02a · `swift run bench-wer --set bench/ar-sa --engine all --with-zoom-load` (Zoom test call + YouTube playing, 30 min) → per engine: `wer_ar`, `wer_en`, `partial_lag_p50/p95_ms`, peak RSS, `vm_stat` pageouts. Pass: `wer_ar<=0.30 wer_en<=0.15 partial_lag_p50_ms<=700 rss_mb<=900 pageouts_growth=0`. Writes `docs/adr/001-stt.md`; no pass → Plan B.
- **T02b [mac] Saudi fine-tune conversion (time-box 1 day)** · `mac/Models/` · T02 · convert `oddadmix/whisper-large-v3-arabic-dialectal-v2` to WhisperKit CoreML; rerun `bench-wer --engine dialect`. Skip if T02 winner already has `wer_ar<=0.25`.
- **T03 [mac] LLM probe** · `mac/Sources/bench-llm/`, `HamsaKit/LLM/Probe*` · T01 · `swift run bench-llm --n 50 --providers groq,gemini` on 2 days → `ttft_p50_ms<=600` for ≥ 1 provider; Arabic check: 10 Saudi questions, answer passes if it is in Arabic script, contains the expected fact from `bench/llm-ar.jsonl`, and has ≤ 3 lines (automatic). Records current free-tier limits + data-use terms (URL + date). Writes `docs/adr/002-llm.md`.
- **T04 [mac] Capture** · `HamsaKit/Audio/`, `hamsa-cli` · T00 · `swift run hamsa-cli capture --seconds 10 --out /tmp/cap` during a Zoom test call → `them.wav me.wav` both `rms_dbfs>-50`; switching output to AirPods mid-run keeps `them.wav` non-silent.
- **T04b [mac] Hide-from-share spike** · `mac/Sources/hamsa-cli/PanelTest.swift` · T00 · `swift run hamsa-cli panel-test` shows an NSPanel with `sharingType = .none`; share screen in Zoom, Teams, Meet (browser) to a second account; `jarvis-screen frame` of the remote view → panel absent in all 3. Fail → `docs/adr/003-overlay-surface.md` (Plan B).

**Phase 1 — Brain (mini PC)**
- **T05 Indexer** · `brain/hamsa_brain/index/`, `schema/` · T01 · `uv run hamsa-brain index refresh --project taweed && uv run hamsa-brain eval retrieval --set ../bench/questions.jsonl` → `recall@5>=0.80` on 40 Q (20 ar-sa phrased by owner or taken from T02a labels, 20 en). Tests: `Secrets/` never indexed; text matching national-ID / phone / IBAN patterns is replaced with `[REDACTED]` and listed in `index/pii-report.txt` (test asserts no raw match remains in `chunks`).
- **T05b [mac] Embedder port** · `mac/Models/`, `HamsaKit/Retrieve/Embed*`, `Sources/bench-match/` · T05 · convert e5-small to CoreML (fp16, ANE) + Swift XLM-R SentencePiece tokenizer (use an existing Swift tokenizer package if one passes, e.g. swift-transformers **[VERIFY]**); `swift run bench-match parity --n 200` → `cosine_min>=0.99 top5_overlap>=0.95` vs brain vectors; model RSS ≤ 300 MB; `embed_ms_p50<=30` per short string with Whisper running.
- **T06 Card generator** · `brain/hamsa_brain/cards/` · T05 · `uv run hamsa-brain cards build --project taweed && uv run hamsa-brain cards stats --project taweed` → `cards>=50 bilingual=100% sources=100%`; pytest rejects an unsourced card.
- **T06a Predictability test (Assumption 2)** · `brain/hamsa_brain/eval/` · T06, T02a · cards built blind (generator never sees T02a labels); `uv run hamsa-brain eval predict --labels ../bench/calls --calls 1-3` → for each tech question, top-3 cards; owner judges match/no-match in `bench-label --judge` (~30 min) → prints `predicted_share`. Gate: ≥ 0.40, else T0 is demoted and T1/T2 become the main path.
- **T07 Brain API + service** · `brain/hamsa_brain/api/`, `brain/deploy/` · T06 · `systemctl --user is-active hamsa-brain` → `active`; `/healthz` with token → `{"ok":true}`, without → `401`; bound only to the Tailscale IP (`ss -ltn` shows no `0.0.0.0:8770`).
- **T07b Sync + upload** · `brain/hamsa_brain/api/sync*`, `HamsaKit/Sync/` · T07 · `swift run hamsa-cli sync` → downloads `index.sqlite`, `cards.sqlite` (second run: `304 not modified`); `swift run hamsa-cli upload --meeting <id>` → brain returns `201` and the meeting row exists in brain DB.

**Phase 2 — Mac live path**
- **T08 Streaming STT + live.sqlite** · `HamsaKit/STT/`, `HamsaKit/Store/` · T02, T04 · `swift run hamsa-cli transcribe --replay bench/calls/call-01.wav --labels bench/calls/call-01.labels.json` → prints `partial_lag_p50_ms` (≤ T02 result + 100) and row counts in `live.sqlite` per channel; `swift test --filter STT` passes; killing the STT worker restarts it within 2 s (`swift test --filter STTRestart`).
- **T09 Question detector** · `HamsaKit/Detect/` · T08, T02a, T05b, T06 · thresholds (`s`, `m`) tuned on calls 1–3; `swift test --filter Detect` → precision ≥ 0.85, recall ≥ 0.80 on calls 4–5 only.
- **T10a Local search (FTS5 + in-memory vectors)** · `HamsaKit/Retrieve/Search*` · T05b, T07b · `swift run bench-match search --set bench/questions.jsonl` → `t1_p50_ms<=150 recall@5>=0.80`.
- **T10b Card matcher** · `HamsaKit/Retrieve/Cards*` · T10a, T06 · `swift run bench-match cards --labels bench/calls` → `t0_match_p50_ms<=100`, precision of shown cards ≥ 0.9 on calls 4–5 (never used in T06a or T09 tuning).
- **T11 T2 streaming client** · `HamsaKit/LLM/` · T03, T10b · `swift run bench-llm --n 50 --with-context` → `ttft_p50_ms<=600 cancel_ok=100% errors=0`; with Groq key removed → Gemini used; confidential flag → no request sent.
- **T11b [mac] Live pipeline** · `HamsaKit/Pipeline/`, `Sources/hamsa-cli/Live.swift` · T08, T09, T10b, T11 · `swift run hamsa-cli live --audio-device loopback` with a looped labelled call → rows in `live.sqlite`, `answer_events` for ≥ 80% of labelled tech questions, `cancel_ok=100%`, memory stable over 10 min (`vm_stat` + RSS log).

**Phase 3 — Mac app**
- **T12 Overlay + latency report** · `mac/App/Overlay/`, `mac/Sources/bench-latency/`, `Sources/bench-report/Latency.swift` · T11b, T04b · if `docs/adr/003-overlay-surface.md` chose Plan B, build `OverlayTransport` (WebSocket to the Jarvis app) instead of NSPanel, acceptance `first_text_p50_ms<=1000` on the phone · `swift run bench-latency --replay bench/calls/call-05.wav --labels bench/calls/call-05.labels.json --ui` → `first_text_p50_ms<=800`, `t2_first_token_p50_ms<=1500`; `swift run bench-report latency` prints the KPI table from `latency_events`.
- **T12b [mac] Soak** · `mac/Sources/bench-soak/` · T12 · `swift run bench-soak --hours 3` while a looped call plays → Hamsa RSS ≤ 1.5 GB at hour 3, swap growth < 500 MB, no crash, hour-3 segments present.
- **T13 Menu bar + onboarding + prepare/start/stop + confidential switch** · `mac/App/Shell/` · T07b, T12 · launch Hamsa.app, finish onboarding, Prepare → "Ready: N cards"; evidence: `jarvis-screen frame` at each step; confidential meeting sends no T2 request (proxy log).
- **T14 Summary** · `brain/hamsa_brain/summarize/`, `brain/tools/make_long_transcript.py` · T07b, T08 · tool builds `bench/calls/long-60min.txt` by joining labelled transcripts; `uv run hamsa-brain summarize --transcript ../bench/calls/long-60min.txt` → vault note with Summary / Decisions / Action items / Open questions in ≤ 120 s; confidential meeting with `claude_allowed=0` → exit 0, no `claude -p` call, no vault note.
- **T15a Learning loop (brain)** · `brain/hamsa_brain/learn/` · T14 · `uv run hamsa-brain learn --meeting <id>` → `pending_review` +N; confidential with `claude_allowed=0` → no-op, exit 0.
- **T15b Review UI (mac)** · `mac/App/Review/` · T15a, T13 · accept one card in ReviewQuestionsView → after `hamsa-cli sync` it is `active` (`bench-report cards`).

**Phase 4 — Gate**
- **T16 Pre-launch security gate** · read-only · all · run audit-workflow items 2 (security), 3 (API auth), 11 (production readiness): brain bound to Tailscale IP only, token required, no secrets in index, Keychain for keys, logs carry no transcript text.
- **T17 Launch: 3 real calls** · — · T16 + counsel answer on consent · owner uses Hamsa on 3 calls; `swift run bench-report --last 3` prints the KPIs from 01-prd.

## Launch criteria
Must work: capture both channels · Arabic + English transcript · cards shown for predicted Qs ·
"Not in your notes" instead of guesses · summary in vault · overlay hidden from screen share (or Plan B
surface) · confidential switch · 3-hour call without crash.
Can be ugly: settings screen · review UI · onboarding polish.
The one thing to test on the first calls: **did the overlay answer arrive before the owner needed to speak?**

## Dependencies
T01 → T04 (T00 → T04) → T02a → T02 (→ T02b) · T01 → T03 · T00 → T04b · T01 → T05 → T05b · T05 → T06 → T06a (gate) · T06 → T07 → T07b ·
T02 + T04 → T08 → T09 (needs T05b, T06) · T05b + T07b → T10a → T10b (needs T06) → T11 (needs T03) → T11b → T12 (needs T04b) → T12b, T13 ·
T07b + T08 → T14 → T15a → T15b (needs T13) · all → T16 → T17.
