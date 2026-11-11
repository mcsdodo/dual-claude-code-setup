#!/bin/sh
# Install the Remote Control server: systemd units, the launcher, the prune
# timer and the two daily version gates. Linux with systemd and cgroup v2 only.
# Idempotent: run it again after you edit a file in this folder.
#
#   sudo sh remote-control/install.sh --user alice --instance work=/home/alice/work --launcher
#   sudo sh remote-control/install.sh --dry-run ...     # print what would change
#
# Options:
#   --user <name>          the user that runs Claude Code. Needed on the first
#                          install; later runs read /etc/claude-rc/host.conf
#   --instance <n>=<dir>   one Remote Control server for <dir>, unit claude-rc@<n>.
#                          Repeat for more directories. Writes
#                          /etc/claude-rc/<n>.conf only if it does not exist
#   --launcher             also replace ~/.local/bin/claude with the launcher
#                          (see claude-launcher.sh for why). Do this once
#   --enable-remote-control
#                          the same as a `y` to "Enable Remote Control? (y/n)",
#                          which the first `claude remote-control` asks. Sets
#                          remoteDialogSeen in ~/.claude.json. Without it a
#                          service gets no answer and exits. Use it only when
#                          the user said yes
#   --dry-run              write nothing
#
# What it writes:
#   /etc/claude-rc/host.conf                 0644, only if it does not exist
#   /etc/claude-rc/<n>.conf                  0644, only if it does not exist
#   /usr/local/lib/claude-rc/common.sh       shared by the root scripts
#   /usr/local/sbin/claude-*                 the scripts
#   /etc/systemd/system/claude-*             the units and timers
#   ~/.local/bin/claude                      only with --launcher
#   ~/.claude.json: remoteDialogSeen         only with --enable-remote-control
#
# It runs `systemctl enable`, NEVER `start` or `restart` for a claude-rc@ unit
# that runs: a restart stops every session in the unit's cgroup, including the
# session that may run this script. A unit change reaches a running server at
# its next restart, normally the 04:30 gate.
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
DRY=0
LAUNCHER=0
ENABLE_RC=0
USER_ARG=
INSTANCES=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY=1 ;;
    --launcher) LAUNCHER=1 ;;
    --enable-remote-control) ENABLE_RC=1 ;;
    --user)     shift; USER_ARG=${1:?--user needs a name} ;;
    --instance) shift; INSTANCES="$INSTANCES ${1:?--instance needs <name>=<dir>}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" != 0 ] && [ "$DRY" = 0 ]; then
  echo "run as root (sudo): this installs system units" >&2
  exit 1
fi

run() { if [ "$DRY" = 1 ]; then echo "    would run: $*"; else "$@"; fi; }
# put <mode> <dest>: write stdin to dest.
put() {
  if [ "$DRY" = 1 ]; then cat >/dev/null; echo "    would write $2 (mode $1)"; return; fi
  tmp=$(mktemp "$2.XXXXXX")
  cat >"$tmp"
  chmod "$1" "$tmp"
  mv "$tmp" "$2"
}

# --- the user -------------------------------------------------------------
HOSTCONF=/etc/claude-rc/host.conf
if [ -r "$HOSTCONF" ]; then
  CLAUDE_USER=$(sed -n 's/^CLAUDE_USER=//p' "$HOSTCONF")
  CLAUDE_HOME=$(sed -n 's/^CLAUDE_HOME=//p' "$HOSTCONF")
  if [ -n "$USER_ARG" ] && [ "$USER_ARG" != "$CLAUDE_USER" ]; then
    echo "$HOSTCONF names user '$CLAUDE_USER', not '$USER_ARG'. Edit or remove it first." >&2
    exit 1
  fi
else
  [ -n "$USER_ARG" ] || { echo "--user is required on the first install" >&2; exit 1; }
  CLAUDE_USER=$USER_ARG
  CLAUDE_HOME=$(getent passwd "$CLAUDE_USER" | cut -d: -f6)
fi
[ -n "$CLAUDE_HOME" ] && [ -d "$CLAUDE_HOME" ] || { echo "no home folder for user '$CLAUDE_USER'" >&2; exit 1; }
CLAUDE_GROUP=$(id -gn "$CLAUDE_USER")
VERSIONS="$CLAUDE_HOME/.local/share/claude/versions"
if [ ! -d "$VERSIONS" ]; then
  echo "$VERSIONS does not exist. Install Claude Code as $CLAUDE_USER first:" >&2
  echo "  curl -fsSL https://claude.ai/install.sh | bash" >&2
  exit 1
fi
echo "==> user $CLAUDE_USER, home $CLAUDE_HOME"
# The Claude app shows the machine by its hostname, and RC_NAME does not change that.
echo "    the Claude app will show this machine as '$(hostname)'. If another machine has"
echo "    that name too, set a unique one: hostnamectl set-hostname <name>"

for t in systemctl journalctl runuser flock python3; do
  command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 1; }
done
command -v jq >/dev/null || echo "    WARNING: jq is not installed. claude-daemon-autoupdate needs it (apt install jq)."
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || echo "    WARNING: no cgroup v2. claude-rc-autoupdate cannot count sessions and never restarts."
[ -f "$CLAUDE_HOME/.claude/.credentials.json" ] || echo "    WARNING: $CLAUDE_USER is not logged in. Run 'claude auth login' as $CLAUDE_USER before you start a server."
# The first `claude remote-control` asks "Enable Remote Control? (y/n)". With no
# terminal the server gets no answer and exits, and Restart=always loops. A `y`
# only sets remoteDialogSeen: true in ~/.claude.json (read from the 2.1.322
# binary), so --enable-remote-control sets the same key. It writes as the user,
# replaces the file atomically and keeps every other key.
rc_enabled() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("remoteDialogSeen", False))' \
    "$CLAUDE_HOME/.claude.json" 2>/dev/null
}
if [ "$(rc_enabled)" != True ] && [ "$ENABLE_RC" = 1 ]; then
  if [ ! -f "$CLAUDE_HOME/.claude.json" ]; then
    echo "$CLAUDE_HOME/.claude.json does not exist. Run 'claude auth login' as $CLAUDE_USER first." >&2
    exit 1
  fi
  echo "==> enable Remote Control for $CLAUDE_USER (remoteDialogSeen in ~/.claude.json)"
  if [ "$DRY" = 1 ]; then
    echo "    would set remoteDialogSeen: true"
  else
    runuser -u "$CLAUDE_USER" -- python3 - "$CLAUDE_HOME/.claude.json" <<'EOF2'
import json, os, sys, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg["remoteDialogSeen"] = True
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".claude.json.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
EOF2
    # A claude that runs as the user rewrites this file from its own copy. Check
    # that the key stayed.
    sleep 2
    [ "$(rc_enabled)" = True ] || echo "    WARNING: remoteDialogSeen did not stay. Stop every claude of $CLAUDE_USER and run this again."
  fi
fi
if [ "$(rc_enabled)" != True ] && [ "$ENABLE_RC" = 0 ]; then
  echo "    WARNING: Remote Control is not enabled for $CLAUDE_USER. If the user agrees, run this again"
  echo "    with --enable-remote-control, or as $CLAUDE_USER run 'claude remote-control' once and answer y."
fi

# Remote Control stops for every claude that reads the gateway env, and the
# server runs plain claude, which reads ~/.claude/settings.json.
CLAUDE_HOME="$CLAUDE_HOME" python3 - <<'EOF'
import json, os
home = os.environ["CLAUDE_HOME"]
for name in ("settings.json", "settings.local.json"):
    p = os.path.join(home, ".claude", name)
    try:
        env = json.load(open(p, encoding="utf-8")).get("env", {})
    except (OSError, ValueError):
        continue
    if "ANTHROPIC_BASE_URL" in env:
        print(f"    WARNING: {p} sets ANTHROPIC_BASE_URL. Remote Control does not work with it."
              " Move it to ~/.claude/litellm-settings.json.")
EOF

# --- config ---------------------------------------------------------------
echo "==> config in /etc/claude-rc"
run install -d -m 0700 /etc/claude-rc
if [ ! -e "$HOSTCONF" ]; then
  sed -e "s|^CLAUDE_USER=.*|CLAUDE_USER=$CLAUDE_USER|" -e "s|^CLAUDE_HOME=.*|CLAUDE_HOME=$CLAUDE_HOME|" \
    "$SRC/host.conf.example" | put 0644 "$HOSTCONF"
fi
for spec in $INSTANCES; do
  name=${spec%%=*}
  dir=${spec#*=}
  case "$name" in
    ""|*[!A-Za-z0-9_-]*) echo "bad instance name '$name': use letters, digits, - and _" >&2; exit 1 ;;
    host) echo "'host' is not a valid instance name: /etc/claude-rc/host.conf is the host config" >&2; exit 1 ;;
  esac
  [ "$dir" != "$spec" ] && [ -d "$dir" ] || { echo "--instance $spec: <dir> must be a folder that exists" >&2; exit 1; }
  # Absolute: the unit runs `cd "$RC_DIR"` from /.
  dir=$(cd "$dir" && pwd -P)
  conf="/etc/claude-rc/$name.conf"
  if [ -e "$conf" ]; then
    echo "    $conf exists, not changed"
  else
    sed -e "s|^RC_DIR=.*|RC_DIR=$dir|" -e "s|^RC_NAME=.*|RC_NAME=$name|" \
      "$SRC/instance.conf.example" | put 0644 "$conf"
  fi
  # The server waits on the trust dialog in a folder that is not trusted, and a
  # background session refuses one with "Workspace not trusted".
  CLAUDE_HOME="$CLAUDE_HOME" DIR="$dir" python3 - <<'EOF'
import json, os
p = os.path.join(os.environ["CLAUDE_HOME"], ".claude.json")
try:
    projects = json.load(open(p, encoding="utf-8")).get("projects", {})
except (OSError, ValueError):
    projects = {}
d = os.path.realpath(os.environ["DIR"])
if not any(projects.get(k, {}).get("hasTrustDialogAccepted")
           for k in (d, os.environ["DIR"])):
    print(f"    WARNING: {d} is not trusted. Start claude there once as the user and accept the dialog.")
EOF
done

# --- scripts --------------------------------------------------------------
echo "==> scripts to /usr/local/sbin and /usr/local/lib/claude-rc"
run install -d -m 0755 /usr/local/lib/claude-rc
run install -m 0644 "$SRC/common.sh"                    /usr/local/lib/claude-rc/common.sh
run install -m 0755 "$SRC/claude-prune-versions.sh"     /usr/local/sbin/claude-prune-versions
run install -m 0755 "$SRC/claude-rc-autoupdate.sh"      /usr/local/sbin/claude-rc-autoupdate
run install -m 0755 "$SRC/claude-rc-restart-verify.sh"  /usr/local/sbin/claude-rc-restart-verify
run install -m 0755 "$SRC/claude-daemon-autoupdate.sh"  /usr/local/sbin/claude-daemon-autoupdate
run install -m 0755 "$SRC/claude-instances.py"          /usr/local/sbin/claude-instances
run install -m 0755 "$SRC/claude-rc-sessions.py"        /usr/local/sbin/claude-rc-sessions

# --- launcher -------------------------------------------------------------
TARGET="$CLAUDE_HOME/.local/bin/claude"
if [ "$LAUNCHER" = 1 ]; then
  echo "==> launcher to $TARGET"
  # Prove that the launcher works BEFORE it replaces the one thing that can run
  # claude. A broken file at this path breaks claude for the user.
  run install -d -o "$CLAUDE_USER" -g "$CLAUDE_GROUP" -m 0755 "$CLAUDE_HOME/.local/bin"
  run install -o "$CLAUDE_USER" -g "$CLAUDE_GROUP" -m 0755 "$SRC/claude-launcher.sh" "$TARGET.new"
  if [ "$DRY" = 0 ]; then
    if ! runuser -u "$CLAUDE_USER" -- env HOME="$CLAUDE_HOME" "$TARGET.new" --version; then
      rm -f "$TARGET.new"
      echo "launcher self-test FAILED, nothing replaced" >&2
      exit 1
    fi
  fi
  # mv in the same filesystem is atomic: claude is never missing.
  run mv "$TARGET.new" "$TARGET"
elif [ -L "$TARGET" ]; then
  echo "    NOTE: $TARGET is the installer's symlink. Without --launcher the updater"
  echo "    can delete the binary that the RC server runs. See claude-launcher.sh."
fi

# --- units ----------------------------------------------------------------
UNITS=/etc/systemd/system
DOC=https://github.com/mcsdodo/dual-claude-code-setup/blob/main/docs/remote-control.md
echo "==> units in $UNITS"
sed -e "s|@CLAUDE_USER@|$CLAUDE_USER|g" -e "s|@CLAUDE_HOME@|$CLAUDE_HOME|g" \
  "$SRC/claude-rc@.service" | put 0644 "$UNITS/claude-rc@.service"

put 0644 "$UNITS/claude-prune-versions.service" <<UNIT
[Unit]
Description=Prune unused Claude Code versions
Documentation=$DOC

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/claude-prune-versions
UNIT

put 0644 "$UNITS/claude-prune-versions.timer" <<'UNIT'
[Unit]
Description=Daily prune of unused Claude Code versions

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT

put 0644 "$UNITS/claude-rc-autoupdate@.service" <<UNIT
[Unit]
Description=Move claude-rc@%i to the newest Claude Code version, if no session is live
Documentation=$DOC
# No After= or Requires= on claude-rc@%i. The script exits when the server does
# not run, and an ordering dependency could pull this unit along with a restart.

[Service]
Type=oneshot
# Belongs to PID 1 in its own cgroup, so the restart of claude-rc@%i does not
# stop it, and it can verify. This is why the timer needs no
# 'systemd-run --on-active=90' as a caller inside the target cgroup does.
ExecStart=/usr/local/sbin/claude-rc-autoupdate %i
UNIT

put 0644 "$UNITS/claude-rc-autoupdate@.timer" <<'UNIT'
[Unit]
Description=Daily check whether claude-rc@%i can adopt a newer Claude Code version

[Timer]
# 04:30, hours away from the prune at 00:00: the prune must never decide which
# binaries are in use while a restart changes the answer.
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

put 0644 "$UNITS/claude-daemon-autoupdate.service" <<UNIT
[Unit]
Description=Move the Claude Code background-session daemon to the newest version, if no background session is live
Documentation=$DOC

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/claude-daemon-autoupdate
UNIT

put 0644 "$UNITS/claude-daemon-autoupdate.timer" <<'UNIT'
[Unit]
Description=Daily check whether the Claude Code background-session daemon runs an old version

[Timer]
# Same time as claude-rc-autoupdate@.timer, for the same reason. The two gates
# touch different processes.
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

run systemctl daemon-reload
run systemctl enable --now claude-prune-versions.timer claude-daemon-autoupdate.timer

# Every /etc/claude-rc/<n>.conf is an instance, from this run or an earlier one.
NAMES=
for c in /etc/claude-rc/*.conf; do
  [ -e "$c" ] || continue
  n=$(basename "$c" .conf)
  [ "$n" = host ] || NAMES="$NAMES $n"
done
for spec in $INSTANCES; do
  n=${spec%%=*}
  case " $NAMES " in *" $n "*) ;; *) NAMES="$NAMES $n" ;; esac
done
for n in $NAMES; do
  run systemctl enable --now "claude-rc-autoupdate@$n.timer"
  # enable, never --now and never restart. See the header.
  run systemctl enable "claude-rc@$n.service"
  if ! systemctl is-active --quiet "claude-rc@$n.service"; then
    echo "    claude-rc@$n does not run. Check /etc/claude-rc/$n.conf, then:"
    echo "    systemctl start claude-rc@$n.service"
  fi
done

echo "==> done. Next: the checks in CLAUDE.md, step 4."
