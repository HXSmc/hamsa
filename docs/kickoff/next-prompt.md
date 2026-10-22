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
**T05 [mini] Indexer** — `brain/hamsa_brain/index/`, `brain/hamsa_brain/schema/` (see 07-engineering-plan T05).
Index the Taweed project (vault `Projects/Taweed*.md`, `Projects/Taweed/`, private repo `docs/`) into
`index.sqlite`: sources, chunks (≤ 800 chars, heading-aware), FTS5, `chunks_vec` + `chunk_vectors`
(`intfloat/multilingual-e5-small`, prefix `passage: `). Skip `Secrets/` and `*.bak*`; redact national-ID /
phone / IBAN patterns into `index/pii-report.txt`. Gold set `bench/questions.jsonl` (40 Q: 20 ar-sa,
20 en) stays local (gitignored; repo is public).
Acceptance: `uv run hamsa-brain index refresh --project taweed && uv run hamsa-brain eval retrieval --set ../bench/questions.jsonl` → `recall@5>=0.80`; pytest: no `Secrets/` path indexed, no raw PII match in `chunks`.

## Founder-gated (waiting on user)
- [ ] T02a: record 5 calls (headphones; paste consent line, or staged calls) + 20 clips, label with `bench-label` (by 2026-11-03) #urgent
- [ ] Create free Groq + Gemini API keys; store in Mac Keychain (`hamsa` service) #soon
- [ ] Grant mic + system-audio permissions on first Mac run #soon
- [ ] Ask counsel the recording-consent question in legal.md #soon

## Done log
- 2026-10-22 · kickoff docs drafted · b4ca53d..f7bd939
- 2026-10-23 · T01 scaffold (swift build + test pass on Linux swift 6.4.1; brain pytest 1 passed; CI added) · see next commit
