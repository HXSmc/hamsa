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

## Result (2026-10-23, full Taweed index: 2,947 chunks sent, 7,341 questions, 0 failed batches, 19.5 min)
Ranked lists measured alone (strict = the gold chunk itself in top 5):

| List | ar strict@5 | en strict@5 |
|---|---|---|
| BM25 | 0.05 | 0.20 |
| chunk vectors | 0.05 | 0.40 |
| generated questions | 0.40 | 0.35 |

Equal-weight fusion dragged Arabic down to 0.10, so fusion is weighted per asker language
(bm25, chunk, questions): ar (0.5, 0, 1), en/mixed (1, 0.5, 1). Brain and Mac use the same weights.

| Metric (40 gold Qs) | all | en | ar |
|---|---|---|---|
| strict recall@5 | 0.475 | 0.50 | 0.45 |
| **judged recall@5** (Claude: a top-5 passage states the answer) | **0.875** | 1.00 | 0.75 |

The T05 gate uses judged recall: Taweed facts repeat across many docs, so "the one gold chunk" undercounts
correct answers. Weights were picked on the same 40 questions (risk of overfit: re-check on the T02a calls).
Arabic (0.75) is the weak side; next lever if real calls confirm it: Arabic paraphrases of the doc text itself.
Mac parity: top-5 overlap 0.99, top-1 40/40, 7.6 ms per search on the mini PC CPU.
