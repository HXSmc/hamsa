# Hamsa kickoff — report (2026-10-22)

## The plan in short
- Mac (M1, 8 GB) does all the live work on the device: it captures call audio and the mic, transcribes, matches questions and shows the overlay.
- Mini PC does the slow work: it indexes the vault and docs, predicts questions, writes answer cards, writes summaries and learns from each call.
- Fast path: a list of likely questions with answers is made before the call. The app matches the live transcript to it and shows an answer before the question has finished (around 0.1 s after a match).
- Fallbacks: if no card matches, the app shows a matching paragraph from your notes (about 0.15 s). It then streams a written answer from Groq's free tier (about 1.5 s).
- Every question asked becomes a new card for the next call.
- Cost: SAR 0.

## Open questions for the owner
1. Should answers be text on the overlay only, or also spoken into an earpiece? I read "accent" as dialect wording, e.g. Saudi Arabic with English tech terms.
2. What macOS version is on the MacBook? Capture needs 14.4 or later. Apple's Arabic speech engine needs 26.
3. Which projects and folders should be indexed first? Which client folders must never be indexed?
4. Will calls only be in Saudi Arabic and English?
5. Do you wear headphones on calls? They are required for clean me/them labels.
6. Must the overlay be hidden from screen share? The plan has a phone fallback if the Mac cannot hide it.
7. Do you have past call recordings or notes? They are needed to test whether questions can be predicted.
8. Is the name "Hamsa" (همسة) okay?
