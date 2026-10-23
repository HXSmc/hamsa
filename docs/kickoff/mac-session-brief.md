# Brief for the Hamsa Mac session

You were started in a new iTerm tab by the mini PC session "Meeting copilot: notes + overlay"
(router id 1151c2c1). Work only in `~/work/hamsa`. Report back as described at the end.

## Rules for this Mac
- **Other iTerm tabs are the owner's Claude sessions. Never touch them**, never type into them, never
  close them. Use only this tab.
- **RAM is 8 GB and 5 other Claude sessions are open.** Before any build or model run, check
  `memory_pressure | tail -1` and `sysctl vm.swapusage`. Build with `swift build -j 2`. If swap goes
  above 6 GB, stop and report instead of pushing on.
- Passwords, Apple ID and permission pop-ups are the owner's. When a macOS pop-up asks for microphone or
  system-audio access, say so in this tab in one line and wait; the owner clicks Allow.
- Never print API keys or tokens.

## Step 0 — copy the session rule into this Mac's CLAUDE.md
Back up `~/.claude/CLAUDE.md` to `~/.claude/CLAUDE.md.bak-2026-10-23-contact`, then append the section
"Keep contact between sessions" below (verbatim) if it is not there yet.

## Step 1 — T00 env check
Run `sw_vers`, `xcodebuild -version`, `security find-identity -v -p codesigning`, `sysctl hw.memsize`,
`swift --version`. If macOS >= 26, check whether `SpeechTranscriber` supports `ar_SA` and whether its asset
downloads (a 20-line Swift script is fine). Write the results to `docs/adr/000-env.md`.
No Xcode: install it is owner-only (App Store); write that in the ADR and stop after Step 1.

## Step 2 — build + test the package on the Mac
`cd mac && swift build -j 2 && swift test` — must pass (CI already passes on macos-latest).

## Step 3 — T04 capture (docs/kickoff/07-engineering-plan.md, T04)
Add `hamsa-cli capture --seconds N --out DIR`: Core Audio tap on all processes except Hamsa itself
(macOS 14.4+ process tap; see insidegui/AudioCap, BSD-2, for the pattern) -> `them.wav`; `AVAudioEngine`
mic -> `me.wav`; both 16 kHz mono. Print `rms_dbfs` per file. Acceptance: while a YouTube video plays and
you speak, both files have `rms_dbfs > -50`. Needs the owner to click Allow once.

## Step 4 — T04b panel test (build only)
Add `hamsa-cli panel-test`: shows an NSPanel (non-activating, floating, `sharingType = .none`) with sample
Arabic + English text for 60 s. Do not run the screen-share test; it needs the owner and a second account.

## Keys (only if `~/hamsa-keys.txt` exists)
Line 1 = Groq key, line 2 = Gemini key. Store with
`security add-generic-password -U -s hamsa -a groq -w "$(sed -n 1p ~/hamsa-keys.txt)"` (and `-a gemini` for line 2),
then delete the file. Never echo them.

## Report back
- Commit to a new branch `mac/t00-t04` (from `build/kickoff-t01`) and push it. No PR, no merge.
- Append to the Done log in `docs/kickoff/next-prompt.md`: date, task, commit hash, result.
- End with a short summary in this tab: done / blocked / needs owner. The mini PC session watches the branch.

## Section to append to ~/.claude/CLAUDE.md

# Keep contact between sessions (owner rule, 2026-10-23)

Sessions share devices, repos and services. Never act blind:
- **Before using a shared device or resource** (Mac/Windows screen, a repo or service another session
  works on): check which sessions are on it (on the mini PC: `jarvis-sessions`; here: the iTerm tabs and
  `ListAgents`). If a session is running on that device or resource, message it and agree before acting;
  do not take over its window or files.
- **Say what you take and when you let go.**
- **Handoffs keep a line open**: a session you start gets your name and reports back (done / blocked /
  needs owner). A child always reports to its parent before it ends.
- **If you change something another session owns, tell it** in the same turn.
