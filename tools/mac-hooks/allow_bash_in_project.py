#!/usr/bin/env python3
"""PreToolUse + PermissionRequest hook (Bash): auto-approve every Bash command, except rm whose
targets leave the project.

- No rm in the command            -> allow
- rm whose every target resolves strictly inside the project root -> allow
- anything else (rm outside the project, rm on the root itself or .git, sudo rm,
  rm with $VAR/`cmd` targets, rm hidden in xargs/bash -c/eval) -> no decision,
  so Claude Code falls back to its normal prompt.

Project root = `git rev-parse --show-toplevel` from the session cwd, else the cwd.
A root of / or $HOME is never treated as a project.
"""
import fnmatch
import json
import re
import os
import shlex
import subprocess
import sys

SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&"}
GLOB_CHARS = set("*?[")
RM_WORD = re.compile(r"(?<![\w.-])rm(?![\w.-])")


def project_root(cwd):
    try:
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
        root = out.stdout.strip() if out.returncode == 0 else cwd
    except Exception:
        root = cwd
    root = os.path.realpath(root)
    if root in ("/", os.path.realpath(os.path.expanduser("~"))):
        return None
    return root


def segments(command):
    lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    seg = []
    for tok in lex:
        if tok in SEPARATORS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def inside(path, root):
    """True if path is strictly inside root and not root/.git itself."""
    real = os.path.realpath(path)
    if real == root or real == os.path.join(root, ".git"):
        return False
    return real.startswith(root + os.sep)


def target_ok(arg, cwd, root):
    if "$" in arg or "`" in arg:
        return False
    arg = os.path.expanduser(arg)
    if any(c in GLOB_CHARS for c in arg):
        # Judge a glob by the literal directory it expands in.
        full = os.path.join(cwd, arg)
        base = os.path.realpath(os.path.dirname(full))
        if any(c in GLOB_CHARS for c in os.path.dirname(full)):
            # Glob in a directory part: every match lives under the literal
            # directory before the first glob char, unless '..' climbs back out.
            first = min(full.index(c) for c in GLOB_CHARS if c in full)
            if ".." in full[first:].split("/"):
                return False
            lit = os.path.realpath(os.path.dirname(full[:first]) or "/")
            if lit == root:
                return False  # first glob level could match .git
            return inside(lit, root)
        if base == root:
            # Pattern names children of the root: fine unless it can match .git.
            return not fnmatch.fnmatchcase(".git", os.path.basename(full))
        return inside(base, root)
    return inside(os.path.join(cwd, arg), root)


def decide(command, cwd):
    """Return 'allow' or None (no decision)."""
    try:
        segs = list(segments(command))
    except ValueError:  # unbalanced quotes
        return None
    if not RM_WORD.search(command):
        return "allow"
    root = project_root(cwd)
    if root is None:
        return None
    cur = cwd
    for seg in segs:
        while seg and "=" in seg[0] and not seg[0].startswith("-"):  # VAR=x cmd
            seg = seg[1:]
        if not seg:
            continue
        head = seg[0]
        if head == "cd":
            if len(seg) < 2 or "$" in seg[1] or "`" in seg[1]:
                return None
            cur = os.path.realpath(os.path.join(cur, os.path.expanduser(seg[1])))
            continue
        if head == "rm" or head.endswith("/rm"):
            targets, opts_done = [], False
            for a in seg[1:]:
                if not opts_done and a == "--":
                    opts_done = True
                elif not opts_done and a.startswith("-") and a != "-":
                    continue
                else:
                    targets.append(a)
            if not targets or not all(target_ok(t, cur, root) for t in targets):
                return None
        elif any(RM_WORD.search(t) for t in seg):
            return None  # rm hidden behind sudo/xargs/bash -c/env/etc.
    return "allow"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or os.getcwd()
    if decide(cmd, cwd) != "allow":
        return
    if data.get("hook_event_name") == "PermissionRequest":
        # Answers the prompt itself, incl. the built-in critical-path rm check
        # that a PreToolUse allow cannot skip.
        out = {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}
    else:
        out = {"hookEventName": "PreToolUse", "permissionDecision": "allow",
               "permissionDecisionReason": "auto-approved: no rm outside the project"}
    print(json.dumps({"hookSpecificOutput": out}))

if __name__ == "__main__":
    main()
