# RESUME — Hamsa (meeting copilot) handoff, 2026-10-23 02:56

Whoever picks this up next (a fresh background session, or a human after /clear): read this file and continue from "Next steps". The owner is asleep and has approved doing manual steps (clicks, sign-ins with existing sessions) yourself. Ask them only for things you truly cannot do.

## Task
Personal macOS meeting copilot "Hamsa". It does two things:
- Notes and summary of each call, written into the vault.
- A live overlay that answers technical questions from the vault and project docs, in Saudi Arabic or English, in under 1 s.

The owner also gave two standing rules today. Both are now in `~/.claude/CLAUDE.md` and in vault memory:
1. **Keep contact between sessions.** Run `jarvis-sessions` before using a shared device, and message the other sessions.
2. **After the owner approves a plan, do the manual steps yourself.** Ask only when it's impossible. Recording consent and legal advice are the owner's job; don't chase them.

## Where things are
- **Repo:** https://github.com/HXSmc/hamsa (public)
  - branch `build/kickoff-t01`, draft PR #1
  - branch `mac/t00-t04`: the Mac session's env-check ADR
- **Worktree (mini PC):** `~/work/meeting-copilot-notes-overlay-e8a0bd/.claude/worktrees/kickoff`. Push with `git push origin HEAD:build/kickoff-t01`.
- **Durable clone + running service:** `~/work/hamsa`
  - systemd user unit `hamsa-brain`: Tailscale IP only, port 8770
  - token in `~/.config/hamsa/token`
- **Data:** `~/.local/share/hamsa/` holds `index.sqlite` (3,044 chunks, 7,341 Claude-written questions) and `cards.sqlite` (66 Taweed cards).
- **Project config:** `~/.config/hamsa/projects.toml`
- **Docs:** `docs/kickoff/`
  - `REPORT.md`: the owner's to-do page
  - `next-prompt.md`: the build loop
  - `mac-session-brief.md`
  - `docs/adr/004-retrieval.md`
- **Helper:** `~/.local/bin/jarvis-sessions` lists router sessions plus the Mac agentic-os hubs.

## State on the Mac
- iTerm **tab 7**, titled "Mac session brief": a Claude session in `~/work/hamsa`, started by us.
  - It is idle and waiting.
  - Its git email is set to the noreply address.
  - Tabs 1–6 belong to the owner. **Never touch them.** Opus 3 holds an unsent owner draft.
- **Xcode is NOT installed.** Only CLT Swift 5.8 with the 13.3 SDK. Swap is 6.6 of 7.2 GB. The owner said "I'll sign in tomorrow".
- **Gemini API key: DONE.**
  - Free tier, key "Default Gemini API Key", project gen-lang-client-0119895782.
  - Stored in the Mac Keychain as service `hamsa`, account `gemini`.
  - The clipboard has been cleared. The key was never printed.
- Safari: we added a tab with AI Studio. The owner's other tab (KCL Saudi Society) was left alone.

## Next steps (in order)
1. **Groq key.**
   - Chrome: open a NEW window or tab in the owner's normal Chrome, not the "controlled by automated test software" instance another session uses. Go to https://console.groq.com/keys.
   - If not signed in, use "Continue with Google" (owner's account i0562269690@gmail.com). Create the API key (free tier).
   - Groq shows the key once. Click its copy button, then in tab 7 run `security add-generic-password -U -s hamsa -a groq -w "$(pbpaste)"`, then `printf "" | pbcopy`.
   - If Chrome fails, use Safari. If Groq isn't free, fall back as the owner said: Claude / GLM via allowed tools / agy / a local model. Record that in `docs/adr/002-llm.md`.
2. **Xcode.**
   - Try App Store → Xcode → Get. The Mac App Store may already be signed in.
   - If it asks for a password or Touch ID, stop; the owner does it tomorrow.
   - Check free disk first, in tab 7: `df -h /`. Xcode needs about 12 GB plus room to unpack.
3. **After Xcode:** in tab 7, "Xcode installed, rerun the brief from Step 1". It then does T00 (SpeechTranscriber ar_SA check), swift build/test, T04 capture and T04b panel test. Click Allow on the mic and system-audio pop-ups via jarvis-screen (owner approved).
4. **Update owner-facing docs:** `REPORT.md` (keys done, Xcode status; remove recording and lawyer items) and the vault `Projects/Hamsa.md` blockers. Commit and push.
5. **T03 LLM probe:** once both keys are in the Keychain and Xcode is installed, run it on the Mac.

## Verified results so far
| Item | Result |
|---|---|
| T01 scaffold | done; CI green on Linux and macOS |
| T05 search (Claude-judged recall@5) | 0.875: English 1.00, Arabic 0.75. Strict score 0.475. |
| Fusion weights | per language (ADR 004) |
| Swift/Python search parity | top-5 overlap 0.99, 7.6 ms |
| T06 cards | 66, bilingual 100%, sourced 100% |
| T07 API | live, 401 without the token |
| T07b sync | verified |
| T14 summary | 60-minute call in 34.7 s |
| T15a learning loop | code and tests pass |
| T09 rules, T10a/b, T11 client | in, CI-tested |
| Card threshold | 0.90, margin 0.02 |
| Tests | brain 17 passed; Swift 13 passed |

## Open owner decisions
- Keep the repo public?
- The `mac/t00-t04` branch has two commits with the owner's Gmail address. Rewriting them needs a force-push and the owner's OK.
- Arabic search scores 0.75: fix now, or wait for real calls?

## Final report (for the owner)

### 1. Do these first
- **Tomorrow:** sign in and install Xcode, unless the App Store download already started.
  - In Terminal: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
  - In Xcode → Settings → Accounts, add your Apple ID.

### 2. What changed tonight
- **New rule in `~/.claude/CLAUDE.md`** (backup: `CLAUDE.md.bak-2026-10-23-approved`): after you approve a plan, sessions do the clicks and sign-ins themselves.
- **Recording consent and the lawyer question** were removed from my trackers.
- **Gemini key:** free tier, now in the Mac Keychain.

### 3. Not done yet
- The Groq key.
- Starting the Xcode download.

### 4. Undo
- Restore the `CLAUDE.md` backup.
- Remove the stored key with `security delete-generic-password -s hamsa -a gemini`.

## Owner instruction 2026-10-23 03:00
Keep this session card in "attention needed" (an open card ask) until the owner has installed Xcode AND the app is finished. Re-post a card ask after every answer until then.

## UPDATE 2026-10-23 16:45 — owner says Xcode is INSTALLED (tapped Yes on the card)
Do next, in this order (owner approved; do clicks yourself via jarvis-screen, ask only if impossible):
1. `jarvis-sessions` + fresh `jarvis-screen frame`. At 16:44 all 5 Mac hubs showed "active" (owner's tabs busy) — never touch tabs 1-6; use only iTerm tab 7 "Mac session brief" (or open a new tab with the "+" button if tab 7 is gone).
2. In tab 7 type: `Xcode installed, rerun the brief from Step 1. Before Step 1 run: sudo -n true || echo NEEDS_SUDO; xcode-select -p` .
   If xcode-select still points at CommandLineTools, the owner's password is needed for `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` → ask on the card (that is owner-only).
3. Click Allow on Microphone / System Audio pop-ups via jarvis-screen.
4. Groq key: Chrome (normal window, not the "automated test software" one) → https://console.groq.com/keys → Continue with Google (i0562269690@gmail.com) → Create API Key → copy → tab 7: `security add-generic-password -U -s hamsa -a groq -w "$(pbpaste)"; printf "" | pbcopy`. Fallback Safari; if Groq is not free → Claude/GLM/agy/local per owner.
5. Then continue the build loop on the Mac: T03 LLM probe, T02 STT bench, T05b embedder port, T08, T11b, T12 overlay, T13 app (docs/kickoff/07-engineering-plan.md).
6. Keep the session card in "attention needed" (an open `jarvis-card ask`) until the app is finished — owner instruction.
Context of this session ran out (~65%); this file is the full state.
