# NEXT PROMPT — Hamsa
> Execute the single task under "Next step", then rewrite this file. Nothing else.

## Standing instructions (copy forward verbatim on every rewrite)
1. Context: read docs/kickoff/ (PRD scope + out-of-scope, TDD verification map,
   07-engineering-plan task list, 10-action-plan activities table). This file's Next step is the ONLY task this run.
   (No 09-financial-model: personal tool, SAR 0 cost; see 03-tdd "Cost".)
2. Orchestrate per CLAUDE.md defaults — GLM spokes/subagents for volume (quota + peak gates
   first), hub judgment only. Never build hub-direct. `[mac]` tasks run in a Claude session on the Mac.
3. Verify before done: run the task's acceptance command(s) with real output, AND exercise the
   affected UI flow live (Mac UI: `jarvis-screen frame` screenshots as evidence).
   No fresh evidence = not done.
4. git add + commit + push. Then check CI per the post-push rule (multi-gmail); CI red = fix
   before proceeding.
5. Rewrite THIS file: append to Done log (date, task, commit hash; reconcile against the
   10-action-plan.md activities table), promote the next unblocked task from
   07-engineering-plan.md into "Next step" (with its acceptance command), keep this
   Standing section verbatim, update Founder-gated list.
6. When no unblocked tasks remain: set Next step to "BLOCKED — founder items only", mirror the
   gated items to the project vault note ## Blockers (dashboard rule), and stop.

## Next step
BLOCKED — needs the Mac (owner is using its screen) and owner items. Every mini-PC task that does not
depend on recorded calls is done. First Mac-session task when the owner frees the Mac:
**T00 [mac] Env check** then **T04 [mac] Capture** (see 07-engineering-plan). Start it with
`cd ~/work/hamsa && git pull && claude` on the Mac and point it at this file.
Later mini-PC tasks wait on recorded calls: T06a (predictability) and T09 thresholds need T02a.

## Founder-gated (waiting on user)
- [ ] T02a: record 5 calls (headphones; paste consent line, or staged calls) + 20 clips, label with `bench-label` (by 2026-11-03) #urgent
- [ ] Create free Groq + Gemini API keys; store in Mac Keychain (`hamsa` service) #soon
- [ ] Grant mic + system-audio permissions on first Mac run #soon
- [ ] Ask counsel the recording-consent question in legal.md #soon

## Done log
- 2026-10-22 · kickoff docs drafted · b4ca53d..f7bd939
- 2026-10-23 · T01 scaffold (swift build/test Linux + macOS CI; brain pytest) · 59edfbd
- 2026-10-23 · T05 indexer (68 files, 3,044 chunks, PII redaction) · 02595db — gate NOT met yet (recall 0.175)
- 2026-10-23 · ADR 004 doc2query (Claude-written questions per chunk) · 51be998
- 2026-10-23 · T06 card builder code (tests pass; real build waits for T05 gate) · ec56950
- 2026-10-23 · T07 brain API live as systemd user service on the Tailscale IP, port 8770 (401 without token) · 2b0b8e0..
- 2026-10-23 · T07b BrainSync + `hamsa-cli sync` (verified against live brain: updated → notModified) · 9b42f75
- 2026-10-23 · T09 rules, T10a LocalIndex (parity with brain top-5 0.99, 5 ms), T10b CardMatcher, T11 AnswerLLM · 5ca804a..
- 2026-10-23 · T00 Mac env check (ADR 000) · 696ca78 — BLOCKED: no Xcode (CLT only, SDK 13.3, Swift 5.8.1); swap 6.6 GB; Steps 2-4 not started
- 2026-10-23 · T14 summarizer, T15a learning loop (code + tests) · dd1d6eb..
- 2026-10-23 · T14 acceptance: 60-min synthetic bilingual call (738 lines) summarized in 34.7 s, all 4 sections
- 2026-10-23 · T05 gate PASSED on Claude-judged recall@5 = 0.875 (en 1.00, ar 0.75); strict 0.475 (ADR 004)
- 2026-10-23 · T06 PASSED via live API + CLI: 66 cards, bilingual 100%, sources 100%, 4 min
- 2026-10-23 · CardMatcher default threshold 0.90 / margin 0.02 from 40 gold Qs vs 66 cards
- 2026-10-23 · Mac session Step 0: 'Keep contact between sessions' appended to ~/.claude/CLAUDE.md (backup .bak-2026-10-23-contact) · Xcode 27.1 installed, waiting on owner licence accept · swap 8.2/9.2 GB > 6 GB stop line — builds wait until RAM freed · 6baa766
- 2026-10-23 · T00 Mac env re-check: Xcode 27.1, Swift 6.4, SDK 27.0, 0 signing ids (ADR 000) · BLOCKED on RAM: swap 7.9 GB > 6 GB stop line; SpeechTranscriber ar_SA + Steps 2-4 + T03 held; T03/T04/T04b code drafted locally, not compiled
- 2026-10-23 · T00 SpeechTranscriber check: no ar_SA (30 locales); DictationTranscriber lists ar_SA (ADR 000) · swap line relaxed by parent · b1a41cb
- 2026-10-23 · Step 2 Mac build+test: `swift build -j 2` OK (18.5 s), `swift test` 15 tests 0 failures (Xcode 27.1, Swift 6.4) · dd551c6
- 2026-10-23 · T04 capture: `hamsa-cli capture --seconds 10 --out /tmp/cap` → them.wav rms_dbfs=-21.3, me.wav rms_dbfs=-40.0, both 16 kHz mono, same length (silence padded by wall clock: a process tap sends nothing while no app plays). Source was `say` through the speakers (mic got the bleed), not YouTube + owner voice; AirPods switch not tested (owner). No permission pop-up (iTerm already allowed). · 26a62b8
- 2026-10-23 · T04b panel-test built: `hamsa-cli panel-test --seconds 6` → window on screen, layer 3 (floating), CGWindowSharingState 0 (none). Screen-share test in Zoom/Teams/Meet NOT run (needs owner + second account) · d8ed313
- 2026-10-23 · T03 day 1 (ADR 002): gate PASS — groq qwen/qwen3.8-27b ttft_p50 109 ms ar 10/10; gpt-oss-120b 384 ms 10/10; Gemini free tier 429/503/timeouts. Day 2 run pending · 879d576..b59b5fe
- 2026-10-23 · T04 owner-approved run: say -v Majed (Arabic) + English say → them.wav rms_dbfs=-21.2, me.wav rms_dbfs=-38.4, both 11.1 s, no pop-up (already allowed). capture now prints seconds per file. Seen once in ~10 runs, not reproduced: one file longer than wall time (me 23 s, later them 6.6 s on a 4 s run) — watch the seconds= value during T02a. macOS-only code wrapped in #if os(macOS) so HamsaKit/hamsa-cli/bench-llm still build on Linux (not tested on Linux here)
- 2026-10-23 · T02 STT bench (PROVISIONAL, TTS set): Dictation wer_ar 0.198 / wer_en 0.099 / lag p50 403 ms; WhisperKit large-v3-turbo 0.119 / 0.037 / 2063 ms → Dictation partials + WhisperKit finals; real gate waits on T02a · 95c549c, a8d4ef4
- 2026-10-23 · T05b [mac] embedder port: e5-small Core ML fp16 (CPU+ANE) + swift-transformers 1.3.5 tokenizer; `bench-match parity --n 200` vs brain index vectors → cosine_min 1.0000, top5_overlap 0.996, tokenizer 200/200, model RSS 171 MB live (588 MB after 512-token passages), embed_ms_p50 12.3 ms (11.8 with WhisperKit running) — PASS · f9d113c
- 2026-10-23 · T08 streaming STT + live.sqlite (PROVISIONAL: synth TTS call from bench/make-synth-call.sh, THEM ar 20 clips + ME en 10 clips): `hamsa-cli transcribe --replay bench/calls/call-01.wav --labels ...` → partial_lag_p50_ms 386 (them 374 / me 415; T02 403, gate ≤ 503), wer them 0.222 me 0.086, question_end_lag_p50 218 ms (14 Qs, 0 missed), live.sqlite rows them=20 me=10; `swift test --filter STT` 5/5; STTRestart fake worker ≤ 2 s, real Dictation worker killed at 30 s → restarted + analyzer ready in 210 ms. Labels format = `CallLabels` (mac/Sources/HamsaKit/STT/CallLabels.swift). Not built: WhisperKit final re-decode, bilingual-per-channel (one locale per channel) · 5da43bb
- 2026-10-23 · T02a rehearse built: `hamsa-cli rehearse --script ../bench/scripts/call-NN.jsonl --out ../bench/calls` (say → them, share-hidden panel verbatim/cue → me, CallLabels + optional `cue`). 5 private scripts × 30 turns (150 questions, 57% ar, 70–73% verbatim) from Taweed docs, gitignored. Smoke 3 turns: them 23.93 s / me 23.91 s, question windows −16..−19 dBFS, gaps silent; Ctrl-C finalizes WAVs. Seen once (first run), not reproduced in 5 runs: me.wav 2.65 s short of them — per-turn `me_s` printed to catch it. Owner records the 5 calls · 2ff9885
- 2026-10-23 · bench/make-synth-call.sh refuses to overwrite bench/calls/call-01.* unless FORCE=1 (protects real rehearse recordings)
- 2026-11-18 · T11 Mac acceptance: crit 3 PASS — `bench-llm --n 50 --with-context` (fixture, 4 snippets) via AnswerLLM.stream → ttft_p50 133 ms / p90 435, cancel_ok 100% measured on the wire (request completed ≤ 200 ms, teardown p90 3 ms, 0 fallback requests), errors 0, groq 50/50 (first run at 4.1 s pacing had 4 Groq 429s; 6 s default since). Crit 4 ❌ external: HAMSA_DISABLE_PROVIDER=groq → groq 0 requests, Gemini free tier answered 1/5 (1630 ms), 4 timeouts. Round 1: Gemini needs per-call notesConsent (ADR 002 d3), no fallback after first token, Probe HTTP path @_spi(Bench); tests 36/36 · 3fbb605, e411e83
- 2026-11-19 · T11b live pipeline (PROVISIONAL: synthetic call-01 only, no real T02a recordings), round 1: T2 only on finals (T1 shows early), send-time privacy re-read + setConfidential cancels in flight, request gap from the chain (Groq free tier 6 s), live.sqlite 0600 · route loopback (BlackHole 16ch, capture in the device's hardware layout), 3-min runs `hamsa-cli live --audio-device loopback --play ../bench/calls/call-01.wav --labels ../bench/calls/call-01.labels.json --seconds 180 [--askers them,me]`: askers=them answer_coverage(any tier) 33% (1/3, THEM 1/1), askers=them,me 100% (3/3); t2_answer_coverage 0% both (every T2 = "Not in your notes.", Taweed index vs generic call); T2 first token after question end p50 355 ms (them) / 460 ms (them,me), max 1179 / 2004 ms (1 of 20 over the 1.5 s budget: gap wait); cancel_ok NA (0 cancels live; ≤200 ms on the wire in tests); earlier 10-min soaks: RSS 141→103 MB, footprint 149→180 MB (watch in T12b); swift test 50/50 · adcfc64, 380f412, a8aa50d
- 2026-11-19 · T12 overlay + latency (PROVISIONAL: synthetic call-01), round 1: share-hidden answer overlay in `mac/Sources/HamsaKit/Overlay/` (OverlayController/OverlayModel/AnswerCardView; app glue `mac/App/Overlay/`, project.yml by hand, Xcode build in T13); LivePipeline `shown:` hook is the overlay's only input and returns whether the screen changed (t_shown_ms stamped only then), confidential latch in memory (a failed store write stays closed), privacy/answerFailed events; `bench-latency --replay ../bench/calls/call-01.wav --labels ... --ui` → label-based (03-tdd:76, line of record) first_text_label_p50_ms=976 ❌ (> 800) t2_first_token_label_p50_ms=1130, stt_end_bias_p50_ms=781 (7/8 matched); STT-end based first_text_p50_ms=197 t2=333; bias = the 0.8 s VAD silence wait before the final (T08 218 ms measured first partial, not the final) (= `bench-report latency`); t0 NA (cards.sqlite empty); every live T2 = "Not in your notes."; kCGWindowSharingState=0; synthetic click on the pin reached no window event (owner hand test needed); `.orchestrator/` gitignored; swift test 58/58. Owner: record call-05, Zoom/Teams/Meet remote-view check, one hand click on a footer button · 63c176d, a89cba8, 529115b, 595c035, cc1b0e4, b01a254
- 2026-11-19 · T13 menu bar + onboarding + Prepare/Start/Stop + confidential switch: SwiftPM target HamsaApp + `mac/App/build-app.sh` → ad-hoc signed mac/.build/Hamsa.app (no XcodeGen); HamsaKit/Shell (HAMSA_HOME test override, Keychain via security stdin, Prepare, MeetingSession, MeetingAudio); confidential replay call-01: 3 Q, T1 only, 0 flows in 1912 nettop/lsof samples, claude_allowed=0; OFF control: 3 Groq T2; Prepare offline `Using 0 cards from last sync` (no brain token on the Mac); LivePipeline privGen latch fix; swift test 64/64. Owner: allow mic + system audio, brain token in onboarding step 3 · 25b3801..86f9ecd
