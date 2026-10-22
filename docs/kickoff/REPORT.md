# Hamsa kickoff — report (2026-10-22)

## The plan in short
- Mac (M1, 8 GB) does all the live work on the device: it captures call audio and the mic, transcribes, matches questions and shows the overlay.
- Mini PC does the slow work: it indexes the vault and docs, predicts questions, writes answer cards, writes summaries and learns from each call.
- Fast path: a list of likely questions with answers is made before the call. The app matches the live transcript to it and shows an answer before the question has finished (around 0.1 s after a match).
- Fallbacks: if no card matches, the app shows a matching paragraph from your notes (about 0.15 s). It then streams a written answer from Groq's free tier (about 1.5 s).
- Every question asked becomes a new card for the next call.
- Cost: SAR 0.

## Open questions for the owner
1. ~~Text only or voice?~~ **Answered 2026-10-22: text only.**
2. **Answered:** MacBook Air M1 8 GB, macOS 26.6.2 (from vault notes; T00 re-checks on the Mac). Apple's on-device Arabic engine is therefore a real candidate.
3. **Answered:** Taweed first; any other project is indexed when a meeting about it is prepared.
4. **Answered:** language follows the other side; always ready for both.
5. **Answered:** AirPods on important calls. Note: while a call uses the AirPods mic, macOS drops them to call-quality audio (16–24 kHz). That is fine for speech recognition.
6. **Answered:** preferably hidden. T04b tests it; phone fallback if it fails.
7. **Answered:** none. The first 5 recorded calls (T02a) double as the prediction test.
8. **Answered:** yes, Hamsa.
