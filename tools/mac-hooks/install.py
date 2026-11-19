#!/usr/bin/env python3
"""Install allow_bash_in_project.py into ~/.claude for every Claude session on this machine.
Run from a git checkout that has the branch fetched:
  git show origin/worktree-mac-rm-hook:tools/mac-hooks/install.py | python3 - origin/worktree-mac-rm-hook
"""
import json, os, shutil, subprocess, sys, time

ref = sys.argv[1] if len(sys.argv) > 1 else "origin/worktree-mac-rm-hook"
home = os.path.expanduser("~")
dest = os.path.join(home, ".claude", "hooks", "allow_bash_in_project.py")
os.makedirs(os.path.dirname(dest), exist_ok=True)
src = subprocess.run(["git", "show", f"{ref}:tools/mac-hooks/allow_bash_in_project.py"],
                     capture_output=True, text=True, check=True).stdout
open(dest, "w").write(src)
os.chmod(dest, 0o755)

path = os.path.join(home, ".claude", "settings.json")
cfg = json.load(open(path)) if os.path.exists(path) else {}
if os.path.exists(path):
    shutil.copy(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
entry = {"matcher": "Bash", "hooks": [{"type": "command", "command": f"python3 {dest}"}]}
hooks = cfg.setdefault("hooks", {})
for event in ("PermissionRequest", "PreToolUse"):
    lst = hooks.setdefault(event, [])
    if not any(dest in json.dumps(e) for e in lst):
        lst.append(entry)
tmp = path + ".tmp"
json.dump(cfg, open(tmp, "w"), indent=2)
json.load(open(tmp))  # validate before replacing
os.replace(tmp, path)
print("HOOK_INSTALLED", dest)
