# ADR 004 — Retrieval: Claude-written questions (doc2query) on top of a small embedder

Date: 2026-10-23 · Status: accepted, pending the T05 recall gate

## Problem
T05 gold set (40 Taweed questions, 20 English + 20 spoken Saudi Arabic, written by a separate agent
without seeing the search code) against 68 files / 3,044 chunks. Measured recall@5:

| Embedder (CPU, mini PC) | query ms | dense en | dense ar | hybrid (BM25+dense) all |
|---|---|---|---|---|
| multilingual-e5-small | 4 | 0.40 | 0.05 | 0.17 |
| multilingual-e5-base | 13 | 0.40 | 0.05 | 0.23 |
| bge-m3 | 43 | 0.40 | 0.30 | 0.28 |

All models plateau near 0.40 in English, and Saudi-dialect questions against mostly English
prose fail. A bigger embedder does not fix it and would not fit the Mac's RAM.
Two question-shaped docs (a sales call script and an open-questions list) win most searches.

## Decision
Offline, Claude (`claude -p --model haiku`, existing subscription, no time limit) reads every chunk and
writes the questions it answers: 2 English + 2 Saudi-dialect, or none for boilerplate. These are embedded
with the same small model (e5-small, `query:` prefix) and become a third ranked list in the hybrid search
(reciprocal-rank fusion with BM25 and chunk vectors). Live matching becomes question to question in the
asker's language, which small on-device models do well. Mac cost: about 1.5 KB per question.

## Rejected
- Bigger embedder (bge-m3 / Qwen3-Embedding): plateau above, about 1 GB+ on an 8 GB Mac.
- LLM re-ranking at question time: seconds of latency; breaks the < 1 s path.
