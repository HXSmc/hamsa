# Hamsa: what I need from you

Updated 2026-10-23 16:50. Xcode 27.1 is installed. Both API keys are in the Mac Keychain.
A Mac session (iTerm tab 8) waits for one step from you, then runs the Mac build.

## 1. Accept the Xcode licence (1 minute, needs your Mac password)
- **Why:** `xcodebuild` refuses to run until the licence is accepted, and `xcode-select` still points
  at the old command-line tools. Both need `sudo`.
- **What to do:** iTerm **tab 7** already has the command typed in. Press Enter, then type your password:
  `sudo xcodebuild -license accept; and sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- **Then:** nothing. Tab 8 sees the change within 60 s and continues (T00, build + test, T04, T04b, T03).
  The mini PC session clicks Allow on the Microphone / System audio pop-ups.
- **Optional:** Xcode, Settings, Accounts: add your Apple ID (free signing identity, so the microphone
  permission survives rebuilds).
- **Memory:** swap was 6.6 of 7.2 GB earlier. Closing Claude tabs you do not need helps the build.

## 2. API keys: done
- Groq (free tier, key "hamsa", no expiry) and Gemini (free tier) are in the Mac Keychain,
  service `hamsa`, accounts `groq` / `gemini`. Groq answered HTTP 200 on 2026-10-23.
- Remove: `security delete-generic-password -s hamsa -a groq` (same with `-a gemini`); revoke at
  https://console.groq.com/keys and https://aistudio.google.com/apikey.

## 3. Record 5 calls + 20 short clips (this week, about 1 hour total)
- **Why:** this test picks the speech engine for Saudi Arabic and tunes when a prepared answer pops up.
  I have no recordings of your calls, so these are the only test data.
- **Calls:** any 5 calls with AirPods on. A practice call with a friend asking you Taweed questions works too.
- **Clips:** 20 short voice notes (30 to 60 seconds), you talking about Taweed the way you would on a call,
  mixing Arabic and English.
- **How:** the Mac session gives you a one-line record command when it is ready. Audio stays on the Mac and the mini PC.

## Decisions you can make anytime
- Repo is **public** (https://github.com/HXSmc/hamsa). Keep it public, or make it private?
- Search on Arabic questions is the weak side (0.75 vs English 1.00). Fix it now, or wait to see real calls first? My pick: wait.

## Done so far (for reference)
| Piece | Result |
|---|---|
| Search over your Taweed notes | 68 files, 3,044 passages; IDs, phones and emails hidden |
| Claude-written questions per passage | 7,341 in Saudi Arabic + English |
| Search quality (Claude-judged, 40 test questions) | 0.875 (English 1.00, Arabic 0.75) |
| Prepared answers for a Taweed tech call | 66 cards, all bilingual, all with sources |
| Summary of a 60-min call into the vault | 35 seconds |
| Mini PC service | running, Tailscale only, refuses requests without the token |
| Mac code that does not need the Mac | sync, question detector rules, search (7.6 ms), card matching, live-answer client; tests pass on macOS CI |

## Earlier answers you gave
Text only · MacBook Air M1 8 GB (macOS 26 per vault notes) · Taweed first, other projects indexed when a meeting about them is prepared ·
language follows the other side · AirPods on important calls · overlay hidden from screen share preferred · no past recordings · name Hamsa.
