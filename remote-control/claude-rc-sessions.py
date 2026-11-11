#!/usr/bin/env python3
"""List Remote Control sessions (started from the phone or claude.ai) on this host.

Why this exists: `/resume` and `claude --resume` filter out every transcript with
`"entrypoint":"sdk-cli"`, and nothing else prints the local session UUID
(anthropics/claude-code#94369, open on 2026-09-15). The transcripts are still on
disk, and `claude --resume <uuid>` still works when you have the UUID.

    claude-rc-sessions            # sessions of the project for the current directory
    claude-rc-sessions --all      # every project
    claude-rc-sessions -n 30      # show more rows (default 15)

LIVE shows the PID when a running process serves the session. Do not resume a
LIVE session: two processes then write to the same transcript.

Run it as the user that runs Claude Code. See docs/remote-control.md ->
"Phone sessions".
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

CLAUDE_DIR = Path(os.environ.get("CLAUDE_HOME") or os.path.expanduser("~")) / ".claude"
PROJECTS = CLAUDE_DIR / "projects"
SESSIONS = CLAUDE_DIR / "sessions"


def slug(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def live_sessions():
    """Map session UUID -> PID for every process that is still alive.

    Any entrypoint counts: after `claude --resume <uuid>` the same UUID runs as
    entrypoint "cli", and resuming it a second time is just as wrong.
    """
    live = {}
    for f in SESSIONS.glob("*.json"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        pid = d.get("pid")
        if pid and Path(f"/proc/{pid}").exists():
            live[d.get("sessionId")] = pid
    return live


def scan(path):
    """Return (is_sdk_cli, title, first_prompt, cwd) for one transcript."""
    sdk = False
    title = prompt = cwd = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"entrypoint":"cli"' in line and not sdk:
                return False, None, None, None
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("entrypoint") == "sdk-cli":
                sdk = True
            cwd = cwd or d.get("cwd")
            for key in ("customTitle", "aiTitle"):
                if isinstance(d.get(key), str):
                    title = d[key]
            if prompt is None and d.get("type") == "user":
                c = d.get("message", {}).get("content")
                if isinstance(c, str):
                    prompt = c
                elif isinstance(c, list):
                    texts = [x.get("text") for x in c if isinstance(x, dict) and x.get("type") == "text"]
                    prompt = texts[0] if texts else None
    return sdk, title, prompt, cwd


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--all", action="store_true", help="scan every project")
    ap.add_argument("-n", type=int, default=15, help="rows to show")
    args = ap.parse_args()

    if args.all:
        files = list(PROJECTS.glob("*/*.jsonl"))
    else:
        project = PROJECTS / slug(os.getcwd())
        if not project.is_dir():
            sys.exit(f"no transcripts for {os.getcwd()} ({project}); try --all")
        files = list(project.glob("*.jsonl"))
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    live = live_sessions()
    rows = []
    for f in files:
        if len(rows) >= args.n:
            break
        sdk, title, prompt, cwd = scan(f)
        if not sdk:
            continue
        rows.append((f, title, prompt, cwd))

    if not rows:
        print("no Remote Control sessions found")
        return
    print(f"{'MODIFIED':16}  {'SESSION UUID':36}  {'LIVE':8}  TITLE / FIRST PROMPT")
    for f, title, prompt, cwd in rows:
        mtime = datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
        label = title or " ".join((prompt or "").split())[:70] or "-"
        if args.all and cwd:
            label = f"[{cwd}] {label}"
        print(f"{mtime:16}  {f.stem:36}  {str(live.get(f.stem, '-')):8}  {label}")
    print("\nresume (from the session cwd): claude --resume <uuid>, then /remote-control")


if __name__ == "__main__":
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")
    main()
