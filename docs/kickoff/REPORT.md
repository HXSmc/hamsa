# Hamsa: what I need from you

Updated 2026-10-23. Everything that can run on the mini PC is built and tested.
The rest needs the Mac and four things only you can do.

## 1. Unlock the Mac (today, 1 minute)
- **Why:** the Mac is on the lock screen. Typing your password is yours only, so I cannot use the Mac
  at all. No other Claude session is using it right now (checked 02:38).
- **What to do:** unlock it and leave it unlocked, or tell me when it is free.
- **What I do next:** open a Terminal and start a Claude session there:
  `git clone https://github.com/HXSmc/hamsa.git ~/work/hamsa && cd ~/work/hamsa && claude`.
  That session checks the Mac (macOS, Xcode), then builds the audio capture.
- **One click from you:** the first run shows macOS pop-ups for the **microphone** and **system audio**.
  Click **Allow** on both. I cannot click permission pop-ups for you.

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
