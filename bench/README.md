# bench/

Test data for the acceptance commands in `docs/kickoff/07-engineering-plan.md`.

- `ar-sa/` — 20 clips (30–60 s, Saudi Arabic / mixed) + reference `.txt` per clip (T02a).
- `calls/` — recorded calls (`call-NN.wav`) + `call-NN.labels.json` (question ends, text, `tech` flag) (T02a).
  Calls 1–3 tune thresholds, calls 4–5 are the held-out test set.
- `questions.jsonl` — retrieval gold set, 40 questions (T05).
- `questions-detect.jsonl` — question-detector labels (T02a).

Audio, labels and the `*.jsonl` sets are never committed (see `.gitignore`): they hold other people's voices
and facts from private project docs. The repo is public; keep that data local.

- Labels format: ONE definition, `CallLabels` in `mac/Sources/HamsaKit/STT/CallLabels.swift` (items: `channel` them/me,
  `start`/`end` s, `text`, `is_question`, `tech`, `verbatim`, optional `lang`; `audio` maps channel → wav).
- `make-synth-call.sh` → `calls/call-01.wav` (THEM, 20 ar clips) + `call-01.me.wav` (ME, 10 en clips) + `call-01.labels.json`:
  PROVISIONAL replay call for T08 built from `synth/` (run `make-synth-set.sh` first). Item `end` = TTS clip end (includes the
  voice's trailing silence), so `question_end_lag_ms` reads low.
- `scripts/call-NN.jsonl` (private, never committed) → `hamsa-cli rehearse --script ../bench/scripts/call-NN.jsonl --out ../bench/calls`
  (run from `mac/`): mock call; `say` plays each question, a share-hidden panel shows the answer (verbatim) or a topic cue
  (own words, `verbatim: false`, `text` empty + `cue` set: label later). Writes `call-NN.wav` / `.me.wav` / `.labels.json`.
- `make-synth-set.sh` → `synth/{ar,en}/NN.wav|txt`: PROVISIONAL TTS set for T02 until `ar-sa/` (T02a) exists. Only the `.txt` refs are committed.
