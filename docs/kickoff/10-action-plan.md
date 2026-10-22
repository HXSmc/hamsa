# 10 Action Plan — Hamsa

> Draft v1, 2026-10-22. Strategy: **Small Wins** — each phase is useful alone
> (Phase 1 alone = searchable vault answers; Phase 2 adds live transcript; Phase 3 = full overlay).

## SMART objectives
1. By 2026-11-05: STT + LLM spikes decided (ADR 001, 002) with measured numbers.
2. By 2026-11-19: brain serves ≥ 50 sourced bilingual Taweed cards, retrieval recall@5 ≥ 0.80.
3. By 2026-12-10: replay bench shows first useful text p50 ≤ 800 ms.
4. By 2026-12-24: 3 real calls done; KPIs from 01-prd reported.

## Activities
| Activity | Owner | Start | End | Resources | Indicator / How measured | Status |
|---|---|---|---|---|---|---|
| Answer open questions (final report §5) | Owner | 2026-10-23 | 2026-10-25 | — | answers in chat | todo |
| Record 20 Saudi-Arabic + mixed clips (30–60 s, own voice + 1 other voice) | Owner | 2026-10-23 | 2026-10-27 | Mac mic | `ls bench/ar-sa/*.wav \| wc -l` = 20 + ref `.txt` | todo |
| Groq + Gemini free API keys into Mac Keychain | Owner | 2026-10-23 | 2026-10-25 | free accounts | `hamsa-bench llm` authenticates | todo |
| T01 scaffold | Claude (mini) | 2026-10-24 | 2026-10-24 | — | T01 command passes | todo |
| T02–T04 spikes | Claude (Mac session) | 2026-10-27 | 2026-11-05 | Xcode | ADR 001/002 written | todo |
| T05–T07 brain | Claude/GLM spokes (mini) | 2026-10-27 | 2026-11-19 | uv, claude -p | T05–T07 commands pass | todo |
| T08–T11 live path | Claude (Mac session) | 2026-11-06 | 2026-12-03 | Xcode | T08–T11 commands pass | todo |
| T12–T15 app | Claude (Mac session) + mini | 2026-11-27 | 2026-12-17 | — | T12–T15 commands pass | todo |
| T16 security gate | Claude reviewer | 2026-12-17 | 2026-12-18 | audit-workflow | gate PASS | todo |
| T17 3 real calls | Owner | 2026-12-18 | 2026-12-24 | real calls | `hamsa-bench report --last 3` | todo |

## Review cadence
Weekly during build (Thursday): compare Done log in `next-prompt.md` against this table; slip > 1 week
on a spike → re-plan before building on top of it.
