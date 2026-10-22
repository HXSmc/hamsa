# 01 PRD — Hamsa (working name, همسة = "whisper")

> Status: draft v1, 2026-10-22. Personal tool, single user (the owner). Not a product for sale.

## Idea overview
A macOS menu-bar app that listens to an online meeting (Zoom, Teams, Meet in a browser) and does two jobs:
1. **Notes + summary** — full transcript, then a structured summary after the call. No time limit.
2. **Answer overlay** — when someone asks a technical question about one of the owner's projects
   (e.g. "what GPU does Taweed run on?"), a small floating card shows the answer, taken from the
   Obsidian vault and project docs, in the same language and dialect the owner is speaking.
   Target: a useful answer on screen **< 1 s** after the question ends, often before it ends.

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
| p50 time from question end to first useful text on overlay | ≤ 800 ms (card / snippet), ≤ 1.5 s (generated first tokens) | `latency_events` table, `hamsa-bench latency` |
| Answer hit rate: questions where the overlay was right and used | ≥ 60% by call 10 | owner taps 👍/👎 on card |
| Card prediction rate: questions matched by a pre-made card | ≥ 40% by call 10 | `questions.matched_card_id not null` |
| Saudi-Arabic transcript WER on owner's own test set | ≤ 25% | `hamsa-bench wer` |
| Summary ready after call end | ≤ 2 min, used without edits in ≥ 7/10 calls | owner rating |

## Top-3 assumptions (each tested in < 2 weeks, SAR 0)
1. **On-device STT on a MacBook Air M1 8 GB can stream Saudi Arabic with partials ≤ 500 ms while Zoom runs.**
   Test: task T02 benchmark on 20 recorded clips of the owner's real calls.
2. **≥ 40% of technical questions in the owner's calls are predictable from the vault before the call.**
   Test: take 3 past call recordings/notes, generate cards blind, count how many real questions match.
3. **A free fast-LLM tier (Groq) gives first token < 500 ms from KSA and enough daily quota for ~30 questions/call.**
   Test: task T03 latency probe, 100 calls over 2 days from the Mac.

## Security / privacy posture (decided now)
- All audio and transcripts stay on the Mac + mini PC (owned devices). Only the question text plus
  retrieved snippets go to the LLM provider, and only for F5.
- No accounts → no 2FA question. API keys live in macOS Keychain, never in files.
- Recording consent is the owner's responsibility per call; app shows a "recording" indicator and a
  one-click consent line to paste in chat (see legal.md).
