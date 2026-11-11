#!/bin/bash
# Move a claude-rc@ instance to the newest usable Claude Code binary, but only
# when that costs nobody their work. Run daily by claude-rc-autoupdate@.timer.
#
# WHY THIS EXISTS
#
# The RC server keeps the binary it started on. It never restarts itself and
# never adopts a new version, while auto-updates keep putting new binaries in
# versions/. The running server and the newest binary drift apart, and
# `systemctl status` says `active (running)` the whole time. Measured: a server
# 15 days and 4 releases behind the newest binary on disk.
#
# A restart by hand stops every session in the cgroup, so it always costs
# somebody their work, and nobody does it. This script restarts in the one
# window where that is free: when the server has no session at all.
#
# It does NOT restart. It decides, then calls claude-rc-restart-verify, which
# does the restart and proves that the server came back.
#
#   claude-rc-autoupdate <instance> [--check]
#
#   --check   decide and log, restart nothing. Safe from inside a live session.
set -uo pipefail

LOG=/var/log/claude-rc-autoupdate.log
# shellcheck source=common.sh
. /usr/local/lib/claude-rc/common.sh

INSTANCE=
CHECK_ONLY=no
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=yes ;;
    -*)      echo "unknown option: $a" >&2; exit 2 ;;
    *)       INSTANCE=$a ;;
  esac
done
[ -n "$INSTANCE" ] || { echo "usage: claude-rc-autoupdate <instance> [--check]" >&2; exit 2; }

UNIT="claude-rc@${INSTANCE}.service"
VERIFY=/usr/local/sbin/claude-rc-restart-verify
# How long a blocked restart stays quiet. After this it logs a WARN line every
# day, because a session left attached on a phone blocks the update forever.
STALE_DAYS=${STALE_DAYS:-7}

# Two runs of this script must never race a restart. Non-blocking: a run that
# finds the lock held lets the other one finish.
exec 9>"/run/claude-rc-autoupdate.${INSTANCE}.lock"
if ! flock -n 9; then
  log "another claude-rc-autoupdate for $INSTANCE holds the lock, exiting"
  exit 0
fi

MAINPID=$(systemctl show "$UNIT" -p MainPID --value 2>/dev/null || echo 0)
if [ -z "$MAINPID" ] || [ "$MAINPID" = 0 ] || [ ! -d "/proc/$MAINPID" ]; then
  # Restart=always, RestartSec=15 and StartLimitIntervalSec=0 already handle a
  # server that does not run. A restart sent into that state only fights them.
  log "$UNIT has no running MainPID (got '${MAINPID:-}'); Restart=always handles this, exiting"
  exit 0
fi

# The version the server actually runs, from its last start. readlink appends
# " (deleted)" when the binary was unlinked under the process. That is the
# deleted-binary failure, so do not remove the suffix here.
RUNNING_EXE=$(readlink "/proc/$MAINPID/exe" 2>/dev/null || true)
RUNNING_VER=${RUNNING_EXE##*/}

# The version the launcher would select now. Ask the launcher, do not scan
# versions/ here: the launcher owns the size floor, the -x test, the version sort
# and the fallthrough. A second copy of that rule would disagree with it on the
# first 0-byte placeholder, and then restart every day for a version that is
# never executed.
SELECTED_VER=$(as_user "$LAUNCHER" --version 2>/dev/null | head -1 | awk '{print $1}')
if [ -z "$SELECTED_VER" ]; then
  log "cannot read a version from '$LAUNCHER --version'; refusing to decide"
  report WARN "Claude RC autoupdate broken on $HOST" \
    "$LAUNCHER --version gave no output, so the gate cannot tell which version to adopt. $UNIT is unchanged, on ${RUNNING_VER:-?}. Log: $LOG"
  exit 1
fi

log "$UNIT MainPID=$MAINPID running=${RUNNING_VER:-<unknown>} selected=$SELECTED_VER check_only=$CHECK_ONLY"

# --- is a restart wanted at all ---------------------------------------------
REASON=""
URGENT=no
case "$RUNNING_EXE" in
  *"(deleted)")
    # Should not occur while the launcher owns ~/.local/bin/claude, because the
    # updater then keeps every version. Handled anyway: this failure reads
    # `active (running)` while every spawn fails with ENOENT.
    REASON="exe is DELETED ($RUNNING_EXE): the deleted-binary bug is back"
    URGENT=yes ;;
  "$VERSIONS"/*)
    if [ "$RUNNING_VER" = "$SELECTED_VER" ]; then
      log "already on the selected version, nothing to do"
      exit 0
    fi
    REASON="running $RUNNING_VER, launcher selects $SELECTED_VER" ;;
  "")
    log "cannot read /proc/$MAINPID/exe; refusing to decide"
    exit 1 ;;
  *)
    REASON="exe is outside $VERSIONS ($RUNNING_EXE)"
    URGENT=yes ;;
esac
log "restart wanted: $REASON"

# --- the gate: any live session blocks --------------------------------------
# Every process other than MainPID that runs a versions/ binary INSIDE THE UNIT'S
# CGROUP is a Claude session. The restart stops the cgroup
# (KillMode=control-group), not only the children of the server: a phone session
# that runs `claude --bg` starts the background daemon in this cgroup, and the
# daemon and its workers live on after the phone session. `pgrep -P` misses them.
# Do NOT try to tell a busy session from an idle one: a healthy session waits in
# ep_poll with no CPU use for half an hour after a turn, and then the user comes
# back to it. Do not use the `Capacity: N/32` journal line either: it is a TUI
# repaint, and LogRateLimitBurst can suppress it.
CGROUP=$(systemctl show "$UNIT" -p ControlGroup --value 2>/dev/null)
PROCS="/sys/fs/cgroup${CGROUP}/cgroup.procs"
if [ -z "$CGROUP" ] || [ ! -r "$PROCS" ]; then
  log "cannot read the cgroup of $UNIT ('$PROCS'); refusing to decide. cgroup v2 is required"
  report WARN "Claude RC autoupdate broken on $HOST" \
    "Cannot read the cgroup of $UNIT ($PROCS), so the gate cannot count live sessions and does not restart. $UNIT stays on ${RUNNING_VER:-?}. Log: $LOG"
  exit 1
fi
SESSIONS=""
while read -r p; do
  [ "$p" = "$MAINPID" ] && continue
  case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
    "$VERSIONS"/*) SESSIONS="$SESSIONS $p" ;;
  esac
done < "$PROCS"
SESSIONS=${SESSIONS# }
NSESS=$(printf '%s' "$SESSIONS" | wc -w)

if [ "$NSESS" -gt 0 ]; then
  # Drift age, from the mtime of the binary on every run. No state file.
  SELECTED_PATH="$VERSIONS/$SELECTED_VER"
  AGE_DAYS=0
  if [ -f "$SELECTED_PATH" ]; then
    MTIME=$(stat -c %Y "$SELECTED_PATH" 2>/dev/null || echo 0)
    [ "$MTIME" -gt 0 ] && AGE_DAYS=$(( ( $(date +%s) - MTIME ) / 86400 ))
  fi
  log "SKIP: $NSESS session(s) live (PIDs: $SESSIONS); selected $SELECTED_VER landed ${AGE_DAYS}d ago"
  # Only the timer run warns. --check stays a plain decision line, so a user who
  # runs it three times to look at a blocked update gets no three warnings.
  if [ "$CHECK_ONLY" = no ] && { [ "$URGENT" = yes ] || [ "$AGE_DAYS" -ge "$STALE_DAYS" ]; }; then
    report WARN "Claude RC is $AGE_DAYS days behind on $HOST" \
      "$UNIT cannot adopt $SELECTED_VER: $NSESS session(s) are live (PIDs: $SESSIONS) and a restart stops all of them.
Reason: $REASON
Free them and the next daily run adopts it, or run: /usr/local/sbin/claude-rc-autoupdate $INSTANCE
Save the session UUIDs first, because /resume hides phone sessions: cat $CLAUDE_HOME/.claude/sessions/<pid>.json
Log: $LOG"
  fi
  exit 0
fi

# --- act ----------------------------------------------------------------------
if [ "$CHECK_ONLY" = yes ]; then
  log "CHECK: would restart $UNIT onto $SELECTED_VER now (0 sessions live)"
  exit 0
fi

if [ ! -x "$VERIFY" ]; then
  log "$VERIFY is missing or not executable; refusing to restart without verification"
  report WARN "Claude RC autoupdate cannot run on $HOST" \
    "$VERIFY is missing, so a restart could not be verified. $UNIT stays on ${RUNNING_VER:-?}. Run remote-control/install.sh again. Log: $LOG"
  exit 1
fi

log "RESTART: 0 sessions live, handing $UNIT to $VERIFY (expect $SELECTED_VER)"
# The verify script owns the restart, the proof and the report. It is safe to call
# it in the foreground here: the oneshot service of a timer belongs to PID 1 in
# its own cgroup, so the restart of claude-rc@ does not stop it.
"$VERIFY" "$INSTANCE" "$SELECTED_VER"
RC=$?
log "verify exit=$RC"
exit "$RC"
