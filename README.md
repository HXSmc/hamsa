# Hamsa (همسة)

A personal macOS meeting copilot for Zoom / Teams / Meet:

1. **Notes + summary** of every call, written into an Obsidian vault.
2. **Answer overlay**: when someone asks a technical question about one of my projects, a small
   floating card shows the answer from my own notes and project docs, in the language of the call
   (Saudi Arabic or English), in under a second.

How it stays under a second: likely questions are predicted before the call and answered offline
(Claude), then matched live on-device from the partial transcript. Unmatched questions fall back to
a note snippet and a streamed answer from a fast free LLM.

Status: early build. Plan and specs live in [`docs/kickoff/`](docs/kickoff/); the build loop is
[`docs/kickoff/next-prompt.md`](docs/kickoff/next-prompt.md).

| Folder | What | Runs on |
|---|---|---|
| `mac/` | Swift package + menu-bar app (capture, transcription, matching, overlay) | MacBook (Apple Silicon, macOS 14.4+) |
| `brain/` | Python service: indexing, answer cards, summaries | always-on Linux box |
| `bench/` | test sets and benchmarks (audio never committed) | both |

Personal project, no support. MIT licence.
