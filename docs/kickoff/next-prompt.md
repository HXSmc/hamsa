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
**T05 gate (in progress)** — finish doc2query for Taweed (`uv run hamsa-brain index questions --project taweed`,
re-runnable), then `uv run hamsa-brain eval retrieval --set ../bench/questions.jsonl` → `recall@5>=0.80`.
If it stays below: next lever is per-language question vectors and dropping question-shaped docs
(sales scripts, open-question lists) from T1; see docs/adr/004-retrieval.md.
After the gate: T06 real build (`hamsa-brain cards build --project taweed`) → `cards>=50 bilingual=100% sources=100%`.
Mac-session tasks waiting for the Mac (T00, T02–T04b, T05b, T08, T11b–T13) — code that does not need macOS
(T07b sync, T09 rules, T10a/b, T11 client) is already in and CI-tested on macOS.

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
- 2026-10-23 · T14 summarizer, T15a learning loop (code + tests) · dd1d6eb..
