# 01 PRD — Hamsa (working name, همسة = "whisper")

> Status: draft v1, 2026-10-22. Personal tool, single user (the owner). Not a product for sale.

## Idea overview
A macOS menu-bar app that listens to an online meeting (Zoom, Teams, Meet in a browser) and does two jobs:
1. **Notes + summary** — full transcript, then a structured summary after the call. No time limit.
2. **Answer overlay** — when someone asks a technical question about one of the owner's projects
   (e.g. "what GPU does Taweed run on?"), a small floating card shows the answer, taken from the
   Obsidian vault and project docs, in the same language and dialect the owner is speaking.
   Target: a pre-made card or note snippet on screen **< 1 s** after the question ends (often before it ends);
   a freshly generated answer starts within 1.5 s.

## Target user (one sentence)
A solo technical founder who runs bilingual (Saudi Arabic + English) calls about their own
projects (Taweed, NoteKit, Nuqra…) and loses credibility when they have to say "let me check and
get back to you" on facts that already sit in their own vault.

## Value prop
Hamsa helps the owner answer technical questions about their own projects instantly during calls
by pre-predicting likely questions from their vault and matching them live on-device, unlike
Cluely-style tools, which send every question to a cloud LLM (2–5 s, no knowledge of their notes,
English-first).

## MVP in one sentence
The owner can start Hamsa before a Taweed call, and within 1 s of a client asking a question that
the vault answers, read a 1–3 line answer in the call's language; after the call they get a
summary note in their vault in under 2 minutes.

## Core features (MoSCoW)
| # | Feature | Priority | Why launch is impossible without it |
|---|---|---|---|
| F1 | Capture call audio (system output = "them") + mic ("me") on separate channels | Must | No audio, no product; split channels give free me/them speaker labels |
| F2 | On-device streaming transcription, Arabic (Saudi) + English, code-switching | Must | Every other feature reads the transcript |
| F3 | Pre-meeting **answer cards**: predicted Q→A per project, generated offline from vault + docs | Must | The only way to hit < 1 s reliably; it is the core idea |
| F4 | Live question detection + card match + extractive snippet fallback, shown in overlay | Must | This is the overlay feature |
| F5 | Streamed generated answer when no card matches (fast free LLM, RAG over vault) | Must | Covers unpredicted questions |
| F6 | Post-call summary + action items written to the vault | Must | Feature 1 of the request |
| F7 | Learning loop: every detected question becomes a reviewed card for the next call | Should | Makes predictions better each meeting; not needed on day 1 |
| F8 | Optional earpiece voice (TTS) of the answer | Could | Only if owner wants it (open question) |

## Out of scope (with revisit trigger)
- Multi-user, accounts, sync, sharing — revisit: never (personal tool).
- Windows app — revisit: if the owner starts taking calls on the Windows PC.
- Joining calls as a bot (Recall.ai style) — revisit: never; local capture is enough.
- Reading the screen / OCR of slides — revisit: after 10 real calls, if questions refer to shared slides.
- Answering general-knowledge questions (not in vault/docs) — revisit: after 10 calls, if > 30% of misses are general knowledge.
- Speaker diarization among multiple remote people — revisit: when summaries need "who said what" beyond me/them.
- "Undetectable" stealth claims — the overlay is hidden from normal screen-share only (`NSWindow.sharingType = .none`); no claim beyond that.
- App Store distribution — revisit: never (self-signed local build), so no account-deletion flow is needed.

## Success metrics (90 days)
| KPI | Target | Measured by |
|---|---|---|
| p50 time from labelled question end to first text (definitions in 03-tdd) | ≤ 800 ms T0/T1; ≤ 1.5 s T2 first token | `latency_events` view, `bench-latency` |
| Answer hit rate: questions where the overlay was right and used | ≥ 60% by call 10 | owner taps 👍/👎 on card |
| Card prediction rate: questions matched by a pre-made card | ≥ 40% by call 10 | `questions.matched_card_id not null` |
| Saudi-Arabic / English transcript WER on owner's own test set | ≤ 30% ar, ≤ 15% en | `bench-wer` |
| Summary ready after call end | ≤ 2 min, used without edits in ≥ 7/10 calls | owner rating |

## Top-3 assumptions (each tested in < 2 weeks, SAR 0)
1. **On-device STT on a MacBook Air M1 8 GB can stream Saudi Arabic with partial lag p50 ≤ 700 ms while Zoom runs**
   (≤ 500 ms is the stretch goal; if only chunked mode passes, mid-question cards are dropped — Plan B in 03-tdd).
   Test: T02 benchmark on the T02a corpus (5 real calls + 20 clips). If it fails: Plan B in 03-tdd.
2. **≥ 40% of technical questions in the owner's calls are predictable from the vault before the call.**
   Test: task T06a — generate cards blind from the vault, then count matches against questions labelled in the 5 T02a calls.
3. **A free fast-LLM tier (Groq) gives first token ≤ 600 ms from KSA and enough daily quota for ~30 questions/call.**
   Test: task T03 latency probe, 50 calls on each of 2 days from the Mac.

## Security / privacy posture (decided now)
- Audio never leaves the Mac + mini PC. Transcript and vault text go to Anthropic via `claude -p`
  (existing subscription) for summaries and cards. For T2, the question plus up to 3 snippets go to a
  free-tier provider (assume it may train on them until T03 proves otherwise).
- Per-meeting **Confidential** switch: T2 off, cards/summary still via `claude -p` only if the owner
  allows it for that meeting, else summary is skipped and only the transcript is kept.
- Headphones are required for clean me/them labels (on speakers the app warns "echo risk").
- No accounts → no 2FA question. API keys and the brain token live in macOS Keychain on the Mac
  (`~/.config/hamsa/token`, mode 600, on the mini PC only).
- Recording consent is the owner's responsibility per call; app shows a "recording" indicator and a
  "Copy consent line" menu item (see legal.md).
