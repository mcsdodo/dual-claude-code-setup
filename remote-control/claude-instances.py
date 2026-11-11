#!/usr/bin/env python3
"""List every Claude Code process on this host, with the version it runs.

Read-only. It changes nothing, so it is safe from inside any session.

WHY THIS EXISTS

`claude --version` answers only one question: which binary the launcher picks
for a NEW process. Every running process keeps the binary it started on, and
several of them never restart on their own: the RC server, the
background-session daemon and any interactive session left open in
tmux. One measured host ran 2.1.235, 2.1.246 and 2.1.280 at once, and the
daemon on 2.1.246 made every backgrounded session fail with
"Claude Code 2.1.246 does not support this model".

  claude-instances

Columns:
  KIND     rc-server | rc-session | daemon | bg-session | bg-spare |
           interactive | vscode-ext | other
  STATE    current = runs the version the launcher selects
           behind  = runs an older or other version
           DELETED = its binary was unlinked (the deleted-binary failure)
  STATUS   idle | busy, from ~/.claude/sessions/<pid>.json. Exit a busy
           session only at a turn boundary.
  UNIT     the systemd unit or scope of the process cgroup. A restart of
           claude-rc@<name> kills EVERY row with UNIT claude-rc@<name>.service,
           not only the children of the server: a daemon started by a phone
           session lives there too.
  SELF     `*` marks an ancestor of this command, that is: you.

The footer prints `cd <cwd> && claude --resume <uuid>` for each session row.
~/.claude/sessions/<pid>.json disappears with the process, so save these
BEFORE anything stops a session.

Run it as the user that runs Claude Code, or as root. It reads CLAUDE_HOME
from the environment, then from /etc/claude-rc/host.conf, else uses ~.
See docs/remote-control.md.
"""
import datetime
import glob
import json
import os
import pwd
import subprocess
import sys

if sys.platform == "win32":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

def claude_home():
    if os.environ.get("CLAUDE_HOME"):
        return os.environ["CLAUDE_HOME"]
    try:
        with open("/etc/claude-rc/host.conf", encoding="utf-8") as f:
            for line in f:
                if line.startswith("CLAUDE_HOME="):
                    return line.split("=", 1)[1].strip().strip('"\'')
    except OSError:
        pass  # no host.conf: ~ is the right home then
    return os.path.expanduser("~")


HOME = claude_home()
VERSIONS = f"{HOME}/.local/share/claude/versions"
LAUNCHER = f"{HOME}/.local/bin/claude"
SESSIONS = f"{HOME}/.claude/sessions"
ROSTER = f"{HOME}/.claude/daemon/roster.json"
DAEMON_LOCK = f"{HOME}/.claude/daemon.lock"
VSCODE_EXT = f"{HOME}/.vscode-server/extensions"


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def ppid_of(pid):
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
            return int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def started(pid):
    # Field 22 of /proc/<pid>/stat is the start time in clock ticks after boot.
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
            ticks = int(f.read().rsplit(")", 1)[1].split()[19])
        with open("/proc/stat", encoding="utf-8") as f:
            btime = next(int(l.split()[1]) for l in f if l.startswith("btime "))
        return datetime.datetime.fromtimestamp(btime + ticks / os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, StopIteration, IndexError):
        return None


def unit_of(pid):
    # cgroup v2: one line "0::/system.slice/.../claude-rc@example.service".
    try:
        with open(f"/proc/{pid}/cgroup", encoding="utf-8") as f:
            path = f.read().strip().splitlines()[-1].split("::", 1)[-1]
        return os.path.basename(path).replace("\\x2d", "-") or "?"
    except (OSError, IndexError):
        return "?"


def selected_version():
    # The launcher reads $HOME. As root, run it as the owner of HOME, so it looks
    # in that user's versions folder and writes nothing as root there.
    cmd = ["env", f"HOME={HOME}", LAUNCHER, "--version"]
    owner = pwd.getpwuid(os.stat(HOME).st_uid).pw_name
    if os.geteuid() == 0 and owner != "root":
        cmd = ["runuser", "-u", owner, "--"] + cmd
    try:
        out = subprocess.run(cmd, capture_output=True, text=True,
                             encoding="utf-8", timeout=30).stdout
        return out.split()[0] if out.split() else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def ancestors():
    out, pid = set(), os.getpid()
    while pid > 1:
        out.add(pid)
        pid = ppid_of(pid)
    return out


def main():
    selected = selected_version()
    roster = read_json(ROSTER) or {}
    roster_hosts = {w.get("pid"): w for w in (roster.get("workers") or {}).values()}
    me = ancestors()

    procs = {}
    for e in glob.glob("/proc/[0-9]*/exe"):
        try:
            exe = os.readlink(e)
        except OSError:
            continue
        if exe.startswith(VERSIONS + "/") or (exe.startswith(VSCODE_EXT) and "native-binary/claude" in exe):
            procs[int(e.split("/")[2])] = exe

    def kind_of(pid, argv, exe):
        if exe.startswith(VSCODE_EXT):
            return "vscode-ext", ""
        if argv[1:2] == ["remote-control"]:
            return "rc-server", ""
        if argv[1:3] == ["daemon", "run"]:
            return "daemon", ""
        # The daemon's helpers retitle argv[0] ("claude bg-pty-host") and repeat
        # it as a flag in argv[1] ("--bg-pty-host"). Look only there: a spare
        # host also carries "--bg-spare" further down, after "--".
        head = (argv[0].split() if argv else []) + argv[1:2]
        is_host = "bg-pty-host" in head or "--bg-pty-host" in head
        if is_host or "bg-spare" in head or "--bg-spare" in head:
            # roster.json lists a claimed worker by its host PID
            w = roster_hosts.get(pid if is_host else ppid_of(pid))
            return ("bg-session", w.get("sessionId", "")) if w else ("bg-spare", "")
        parent = ppid_of(pid)
        if parent in procs and cmdline(parent)[1:2] == ["remote-control"]:
            return "rc-session", ""
        meta = read_json(f"{SESSIONS}/{pid}.json") or {}
        if meta.get("kind") == "interactive":
            return "interactive", meta.get("sessionId", "")
        if meta.get("kind") == "bg":
            return "bg-session", meta.get("sessionId", "")
        if argv[1:2] == ["agents"]:
            return "other", ""
        return "other", meta.get("sessionId", "")

    rows, resume, seen = [], [], set()
    for pid, exe in sorted(procs.items()):
        argv = cmdline(pid)
        kind, uuid = kind_of(pid, argv, exe)
        meta = read_json(f"{SESSIONS}/{pid}.json") or {}
        uuid = uuid or meta.get("sessionId", "")
        deleted = exe.endswith(" (deleted)")
        path = exe[: -len(" (deleted)")] if deleted else exe
        if kind == "vscode-ext":
            # .../anthropic.claude-code-2.1.280-linux-x64/resources/native-binary/claude
            ver = path.split("anthropic.claude-code-")[-1].split("-")[0]
        else:
            ver = os.path.basename(path)
        state = "DELETED" if deleted else ("current" if ver == selected else "behind")
        st = started(pid)
        rows.append([
            "*" if pid in me else "",
            kind, str(pid), ver, state,
            meta.get("status", "") if meta else "",
            st.strftime("%Y-%m-%d %H:%M") if st else "?",
            unit_of(pid),
            meta.get("name", "") or " ".join(argv[1:3])[:28],
            uuid,
        ])
        if uuid and uuid not in seen and kind in ("rc-session", "interactive", "bg-session", "other"):
            seen.add(uuid)
            cwd = meta.get("cwd") or (os.readlink(f"/proc/{pid}/cwd") if os.path.exists(f"/proc/{pid}/cwd") else "")
            resume.append(f"  {pid:>8}  cd {cwd or '<cwd?>'} && claude --resume {uuid}")

    print(f"launcher selects: {selected or '<none: launcher --version failed>'}")
    on_disk = sorted((v for v in os.listdir(VERSIONS) if v.count(".") == 2),
                     key=lambda v: [int(x) if x.isdigit() else 0 for x in v.split(".")])
    print(f"versions on disk: {' '.join(on_disk)}")
    ext = sorted(os.path.basename(d) for d in glob.glob(f"{VSCODE_EXT}/anthropic.claude-code-*"))
    print(f"vscode extension: {' '.join(ext) or '<none>'}")
    lock = read_json(DAEMON_LOCK)
    print("daemon.lock:      " + (f"pid {lock.get('pid')} version {lock.get('version')}" if lock
                                  else "<none: no daemon; the next `claude agents` or `claude --bg` starts one>"))
    print()
    head = ["SELF", "KIND", "PID", "VERSION", "STATE", "STATUS", "STARTED", "UNIT", "NAME", "UUID"]
    widths = [max(len(r[i]) for r in rows + [head]) for i in range(len(head))]
    for r in [head] + rows:
        print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)).rstrip())
    behind = [r for r in rows if r[4] != "current"]
    print()
    print(f"{len(rows)} process(es), {len(behind)} not on {selected or '?'}.")
    if resume:
        print()
        print("resume commands (save these before any session stops):")
        print("\n".join(resume))
    return 0


if __name__ == "__main__":
    sys.exit(main())
