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
- 2026-10-23 · Mac session Step 0: 'Keep contact between sessions' appended to ~/.claude/CLAUDE.md (backup .bak-2026-10-23-contact) · Xcode 27.1 installed, waiting on owner licence accept · swap 8.2/9.2 GB > 6 GB stop line — builds wait until RAM freed
