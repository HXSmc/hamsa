# Legal / privacy notes — Hamsa (personal tool)

> Draft v1, 2026-10-22. Drafting aid only — KSA-law items need licensed counsel.

## Scope
Personal use by the owner only. No users, no sales, no ToS, no payments → no merchant-of-record,
privacy policy, or subscription rules apply.

## The real risk: recording other people
Hamsa records and transcribes the other people on the call. Laws on recording calls differ by
country (one-party vs all-party consent), and KSA has rules on privacy and on personal data.
- The KSA Law Pack in the vault (`Reference/KSA Law/KSA Law Pack.md`) has **no note** on the
  Anti-Cyber Crime Law or the PDPL, so no article is cited here. Do not treat this file as a
  legal answer. **Blocker for counsel:** "Is recording + transcribing a business video call
  lawful in KSA with verbal/chat notice, and what notice wording is enough?"
- Safe default built into the app until counsel answers:
  1. Menu item "Copy consent line" (never auto-overwrites the clipboard) to paste in the meeting chat:
     "FYI I take AI notes of this call for my own records. / للعلم أسجّل ملاحظات المكالمة بالذكاء الاصطناعي لاستخدامي الشخصي."
  2. Red menu-bar dot whenever capturing.
  3. Audio stays on owned devices. Transcript text goes to Anthropic (`claude -p`) for summary/cards;
     question + ≤ 3 snippets go to the T2 free-tier provider. "Confidential" meeting switch turns T2 off.
  4. Audio auto-deleted after 30 days; delete-meeting removes everything.
  5. Client confidential material (e.g. Taweed/NPHIES patient data) is never indexed: the indexer
     only reads folders listed per project, skips `Secrets/`, and a T05 test fails the build if a
     chunk matches national-ID / phone / IBAN patterns.

## Third-party provider terms
- **GLM Coding Plan**: its docs restrict use to supported coding tools. Use GLM only to *build*
  Hamsa (through supported coding tools), never as the app's runtime LLM.
- **Groq / Gemini free tiers**: free-tier prompts may be used by the provider per their terms
  **[VERIFY in T03]**; if so, keep T2 off for calls marked "confidential" (setting per meeting).
- **Claude (`claude -p`)**: runs under the owner's existing subscription on the owner's own box.

## OSS licences of borrowed code
WhisperKit/argmax-oss-swift MIT · FluidAudio Apache-2.0 · AudioCap BSD-2 · sqlite-vec Apache-2.0 ·
multilingual-e5-small MIT · Meetily MIT (templates only). All allow personal use and modification; keep
licence headers. Do **not** copy code from Pluely (GPL-3.0) unless the repo goes GPL. OpenCluely is Apache-2.0 (ok to borrow with notice).

## Founder-gated
- [ ] Ask counsel the recording question above — before the first call with an outside party (T17) #soon
