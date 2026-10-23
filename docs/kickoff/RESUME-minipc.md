# RESUME — Hamsa (meeting copilot). READ THIS FIRST after the 2026-10-23 ~21:00 mini PC reboot

## FIRST ACTION (exact step to return to)
1. Run `jarvis-card ask yesno "Back after the mini PC reboot. Tab 8 on the Mac is still ready: type go there when free (mock call, ~10 min). Want me to continue building (overlay + app, T11/T11b/T12/T13) in a NEW Mac tab now?"` and end the turn. Wait for the owner's answer.
2. If Yes, open a NEW iTerm tab on the Mac (the "+" button). Never use tabs 1-8: tab 8 is the rehearsal runner. Before using the screen, run `jarvis-sessions` and ListAgents. In the new tab, start `cd ~/work/hamsa; claude --dangerously-skip-permissions '<brief>'`. The brief: follow docs/kickoff/next-prompt.md for T11, T11b, T12, T13 (docs/kickoff/07-engineering-plan.md), branch mac/t00-t04, commit + push per task, stop on critical memory pressure or <3 GB free disk, print OWNER_NEEDED for owner-only steps, never touch other tabs, never ssh into the mini PC. First re-sync the Mac index (Mac has 1,124 questions, brain has 7,341).
3. Keep an open `jarvis-card ask` until the app is finished (owner instruction). Attach a "What I need from you" file with every ask (CLAUDE.md rule).

## State at 20:55
- Mac tab 7 is a spare fish shell. Mac tab 8 is the "Hamsa rehearsal runner" Claude session, idle and READY. The owner types `go` to start mock call N (hamsa-cli rehearse; 5 scripts in ~/work/hamsa/bench/scripts, gitignored). Calls recorded: 0 of 5.
- Done on mac/t00-t04: T00, T02 (provisional), T03 day 1 (Groq qwen3.8-27b, 109 ms), T04, T04b build, T05b, T08 (provisional), T02a rehearse.
- Open: T03 day-2 run, the T04b screen-share test (needs the owner + a second account), the WhisperKit second pass, and mixed Arabic/English sentences in one channel.

# RESUME — Hamsa (meeting copilot), 2026-10-23 16:53

Older full state: ~/.claude/jobs/b5e621a3/tmp/resume.md. Repo work committed + pushed (build/kickoff-t01).

## Done this session
- Groq key (free, "hamsa") in Mac Keychain hamsa/groq, HTTP 200 test. Gemini already there.
- REPORT.md updated + pushed; vault Projects/Hamsa.md blockers updated.
- Mac iTerm tab 8: Claude session in ~/work/hamsa (branch mac/t00-t04). Polls xcode-select -p every 60 s (max 3 h), then brief Steps 1-4 + T03. Swap 8.2 GB (over 6 GB stop line).
- Owner ran sudo line in tab 7 at 16:52: FAILED, xcodebuild ran before xcode-select.
- My retry went into App Store search (owner had it focused); search cleared. Owner active at Mac.

## Next step
1. jarvis-screen frame first. Type only if iTerm tab 7 is focused.
2. If licence still not accepted: card ask owner to run in tab 7, this order:
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer; and sudo xcodebuild -license accept
3. Watch tab 8; click Allow on mic/system-audio pop-ups when it prints ALLOW_NEEDED.
4. Ask owner to close spare Claude tabs (swap 8.2 GB).
5. Keep a jarvis-card ask open until app finished (owner instruction).

No mini PC processes/downloads to restart.

## UPDATE 17:28
- Xcode selected + licence accepted (XCODE_READY in tab 7). Simulators: none installed.
- Disk was full: 118.7 GB of stale Chrome code_sign_clone copies in /private/var/folders/fx/.../X/. Deleted 65 of 66 (>1 day old). Free 7.8 GB and rising. npm cache cleaned too.
- Tab 8 Mac session is building (working). Next: watch tab 8 (frame), click Allow on mic/system-audio pop-ups, then T03 and the rest of the build loop. Keep a card ask open.

## UPDATE 17:30
- I relaxed tab 8's swap rule: it now stops only on critical memory pressure or <3 GB free disk.
- T00 done (b1a41cb on mac/t00-t04): SpeechTranscriber has NO ar_SA (30 locales). DictationTranscriber lists ar_SA. Feeds T02 STT choice.
- Tab 8 is on Step 2 (swift build -j 2 + test). Next: watch with frames; click Allow on mic/system-audio pop-ups at Step 3 (T04 capture).
- This session's context is full. A fresh session should pick up from this file.

## UPDATE 17:37
- mac/t00-t04 now has dd551c6 (swift build + test PASS on the Mac), 26a62b8 (T04 capture code), d8ed313 (T04b panel-test code).
- Tab 8 is running T03: `swift run bench-llm --n 3 --providers groq,gemini` (groq gpt-oss-120b / qwen3 / allam; gemini 3.5 flash / flash-lite).
- Not yet verified: has the T04 capture actually run (mic + system-audio Allow pop-ups)? Check tab 8's output and the Done log.

## UPDATE 17:45
- 879d576 T03 bench-llm committed (19 tests pass). Full T03 day-1 run (n=50, 6 s pacing) runs in background on the Mac, ~30 min (ends ~18:15). Then: ADR 002-llm, T04 capture run (Allow pop-ups), next build-loop tasks.

## UPDATE 18:27
- T03 day 1 PASSED (b59b5fe, docs/adr/002-llm.md): Groq qwen/qwen3.8-27b TTFT p50 109 ms, Arabic 10/10. Gemini free tier unusable (429/timeouts) and its free-tier data terms allow human review, so it is NOT for confidential calls.
- Next: T03 day-2 run tomorrow; T04 capture run (Allow pop-ups); then T02 STT bench (DictationTranscriber vs Whisper), T05b, T08, T11b, T12, T13.

## UPDATE 18:30
- T04 capture PASSED (26a62b8, 233d6fe): them.wav -21.2 dBFS, me.wav -38.4 dBFS, no pop-up (iTerm already had permission). T04b panel shows (d8ed313); share test needs owner.
- Tab 8 was told to continue the Mac build loop: T02, T05b, T08, T11+T11b, T12, T13. Watch for OWNER_NEEDED lines. Check mac/t00-t04 commits and the Done log.
- Watch: odd file length seen twice in capture; qwen3.8-27b is "Preview" on Groq (gpt-oss-120b is the backup).

## UPDATE 19:04
- T02 provisional (95c549c, ebfcd81), TTS test set: Dictation WER ar 0.198 / en 0.099 / lag p50 403 ms; WhisperKit large-v3-turbo 0.119 / 0.037 / 2063 ms. Plan: Dictation for live partials, WhisperKit for finals. Real gate waits on T02a (owner recordings).
- Tab 8 continues: T05b, T08, T11/T11b, T12, T13.

## UPDATE 19:37
- T02 done, CI green (6c52a9b). T05b embedder port running in a tab-8 subagent (18 min in, working on RSS measurement).
- Tab 8 OWNER_NEEDED: T02a — 5 calls + 20 clips via `hamsa-cli capture`, label with `bench-label`. Until then T02/T08/T11b/T12 only test on synthetic audio. Also the Zoom-load T02 run needs the owner to start a call.

## UPDATE 20:04 — owner idea, sent to tab 8
- Replace free T02a recordings with `hamsa-cli rehearse --script bench/scripts/call-NN.jsonl`: mock call. `say` plays the caller's question, the T04b panel shows what the owner should answer. 70% verbatim lines (auto ground truth), 30% topic cues (natural speech, labelled later). 5 scripts of ~10 min each from real Taweed cards. ADR 001 must note that read speech flatters WER. Tab 8 prints OWNER_NEEDED with the start command.

## UPDATE 20:48 — rehearsal (20:52: owner busy, call 1 NOT started; owner types go later)
- Tab 8 was cleared with /clear and is now the "Hamsa rehearsal runner". The owner types `go` and it runs the next `hamsa-cli rehearse` call (5 scripts in bench/scripts/, gitignored), then scores WER, commits, pushes and says "type go".
- T05b (f9d113c) and T08 (5da43bb) are done. T11, T11b, T12, T13 have not started. Start them in a NEW Mac tab, not tab 8.
- Flags: a tab-8 subagent ssh'd into the mini PC without asking. The Mac index has 1,124 questions, the brain has 7,341, so re-sync.
