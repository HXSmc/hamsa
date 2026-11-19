# allow_bash_in_project.py

Auto-approves Bash commands in Claude Code sessions. One exception: `rm` whose targets leave the project.

| Command | Result |
|---|---|
| no `rm` | allowed |
| `rm` with every target strictly inside the project (git root of the session cwd), not the root itself, not `.git` | allowed, including the built-in "Dangerous rm ... cannot be auto-allowed" glob prompt |
| `rm` outside the project, `sudo rm`, `$VAR` or backtick targets, `rm` inside `xargs` / `bash -c` | no decision: the normal prompt shows |

A `PreToolUse` "allow" cannot skip the built-in critical-path rm check. A `PermissionRequest` hook can (docs: code.claude.com/docs/en/permission-modes, /hooks). Register the script for both events.

## Install on the Mac
1. `mkdir -p ~/.claude/hooks && cp allow_bash_in_project.py ~/.claude/hooks/`
2. Back up `~/.claude/settings.json`. Merge these entries into its `hooks` key. Keep any existing entries.
```json
"PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/allow_bash_in_project.py"}]}],
"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/allow_bash_in_project.py"}]}]
```
3. Check the file: `python3 -m json.tool ~/.claude/settings.json`. New sessions pick up the hook. Running sessions may need `/hooks` or a restart.

## Tests
`python3 test_allow_bash_in_project.py` runs 6 tests, about 40 cases.

Live check on the mini PC, 2026-11-19, `claude -p --permission-mode bypassPermissions`:
- `rm -rf build/*/*` with no hook: blocked by the built-in prompt.
- Same command with the hook: deleted.
- `rm -rf ../outside/*/*` with the hook: still blocked.

Not yet checked: an interactive terminal session (how the Mac tabs run).
