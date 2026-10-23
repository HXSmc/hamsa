# Hamsa: what I need from you

Updated 2026-10-23 02:48. Everything that can run on the mini PC is built and tested. The Mac session is started (iTerm tab 7) and waits for Xcode.
The rest needs the Mac and four things only you can do.

## 1. Install Xcode on the Mac (today, about 30-60 minutes, mostly download)
- **Why:** the Mac session started (iTerm tab 7) and checked the Mac. It has **no Xcode**, only old
  command-line tools (Swift 5.8, macOS 13.3 SDK). Hamsa needs the macOS 26 SDK to capture call audio
  and to build the app. Installing apps with your Apple ID is yours only.
- **What to do:**
  1. App Store, search **Xcode**, click Get/Install (about 12 GB, check free disk space first).
  2. Open Xcode once and accept the licence.
  3. In Terminal: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (asks your password).
  4. Xcode, Settings, Accounts: add your Apple ID (free). This gives a signing identity, so macOS
     keeps the microphone permission between builds.
- **Free some memory before builds:** the Mac's swap was 6.6 of 7.2 GB used, with 5 Claude tabs open.
  Close the Claude tabs you don't need.
- **Then:** in tab 7 type `Xcode installed, rerun the brief from Step 1`. When macOS asks for
  **Microphone** and **System audio** access, click **Allow**.
- **Still owner-only:** the Mac's safety check blocked the Mac session from adding the
  "keep contact between sessions" rule to the Mac's `~/.claude/CLAUDE.md`. Paste it yourself from the
  bottom of `docs/kickoff/mac-session-brief.md`, or approve that edit when the session asks.

## 2. Make two free API keys (10 minutes)
They are for live answers when no prepared answer matches.
1. Groq: go to https://console.groq.com, sign in, go to API Keys, then Create API Key.
2. Gemini: go to https://aistudio.google.com/apikey, sign in, then Create API key.
- **Where to put them:** paste each key into a file on the Mac, `~/hamsa-keys.txt`, one per line.
  The Mac session moves them into the Keychain and deletes the file.
  Never paste keys in chat.

## 3. Record 5 calls + 20 short clips (this week, about 1 hour total)
- **Why:** this test picks the speech engine for Saudi Arabic and tunes when a prepared answer pops up.
  I have no recordings of your calls, so these are the only test data.
- **Calls:** any 5 calls with AirPods on. Real calls are fine if you paste the consent line in the chat
  first ("FYI I take AI notes of this call for my own records. / للعلم أسجّل ملاحظات المكالمة بالذكاء الاصطناعي لاستخدامي الشخصي.").
  A practice call with a friend asking you Taweed questions works too.
- **Clips:** 20 short voice notes (30 to 60 seconds), you talking about Taweed the way you would on a call,
  mixing Arabic and English.
- **How:** the Mac session gives you a one-line record command when it is ready. Audio stays on the Mac and the mini PC.

## 4. Ask a lawyer one question (before calls with outside people)
"Is it legal in Saudi Arabia to record and transcribe a business video call for my own notes,
if I tell the other side in the chat? What wording is enough?"
Until you have the answer, use the app on practice calls or with the consent line.

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
