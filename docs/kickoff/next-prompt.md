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
**T01 [mini] Scaffold** (T00 runs in the first Mac session; T01 does not need it) — create the layout in
07-engineering-plan "Repo layout": `mac/Package.swift` with every target and an empty `main.swift` each,
`mac/App/project.yml`, `brain/` uv project `hamsa_brain` with CLI entry `hamsa-brain` and one smoke test,
`brain/hamsa_brain/schema/` (empty `001_init.sql` with `schema_version`), `bench/README.md` + `.gitignore`
for audio, `docs/adr/`.
Ownership: `mac/`, `brain/`, `bench/`, `docs/adr/`.
Acceptance: `test -f mac/Package.swift && (cd brain && uv run pytest -q)` → `1 passed`.

## Founder-gated (waiting on user)
- [ ] Answer kickoff open questions (final report §5) #urgent
- [ ] T02a: record 5 calls (headphones; paste consent line, or staged calls) + 20 clips, label with `bench-label` (by 2026-11-03) #urgent
- [ ] Create free Groq + Gemini API keys; store in Mac Keychain (`hamsa` service) #soon
- [ ] Grant mic + system-audio permissions on first Mac run #soon
- [ ] Ask counsel the recording-consent question in legal.md #soon
- [ ] Create GitHub repo + `git remote add origin` — blocks the first Mac session (2026-10-24) #urgent

## Done log
- 2026-10-22 · kickoff docs drafted · (see git log)
