# bench/

Test data for the acceptance commands in `docs/kickoff/07-engineering-plan.md`.

- `ar-sa/` — 20 clips (30–60 s, Saudi Arabic / mixed) + reference `.txt` per clip (T02a).
- `calls/` — recorded calls (`call-NN.wav`) + `call-NN.labels.json` (question ends, text, `tech` flag) (T02a).
  Calls 1–3 tune thresholds, calls 4–5 are the held-out test set.
- `questions.jsonl` — retrieval gold set, 40 questions (T05).
- `questions-detect.jsonl` — question-detector labels (T02a).

Audio, labels and the `*.jsonl` sets are never committed (see `.gitignore`): they hold other people's voices
and facts from private project docs. The repo is public; keep that data local.
