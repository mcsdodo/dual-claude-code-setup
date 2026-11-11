#!/bin/bash
# Move the Claude Code background-session daemon to the newest usable binary,
# but only when no background session is live. Run daily by
# claude-daemon-autoupdate.timer.
#
# WHY THIS EXISTS
#
# `claude --bg`, a session sent to the background and `claude agents` all use
# one on-demand daemon (`versions/<v> daemon run ... --origin transient`). Every
# background session runs on the DAEMON's binary. The daemon upgrades itself
# only when realpath(~/.local/bin/claude) changes. With the launcher from this
# folder that path is a regular file, so the realpath never changes: the
# launcher causes this problem, and this script is its fix. The daemon also
# never exits while a client or a worker holds it.
#
# Measured on 2.1.246 to 2.1.280: the daemon ran 2.1.246 for 26 days. Newer
# clients gave its spares a flag that they did not know:
#   bg settled 9ac590e9 (crashed): exit 1 before init -- error: unknown option '--inherit-permission-mode'
# and then every background session on a new model failed with
#   API Error: 400 Claude Code 2.1.246 does not support this model; version 2.1.280 or newer is required.
#
# The fix is `claude daemon stop --any`. The next `claude agents`, `claude --bg`
# or background session starts a new daemon through the launcher, on the newest
# binary. The stop is free only when no background session is live. Do not rely
# on --keep-workers: nothing shows that a kept worker survives the stop and that
# the next daemon adopts it.
#
#   claude-daemon-autoupdate [--check]
#
#   --check   decide and log, stop nothing. Safe from anywhere.
set -uo pipefail

LOG=/var/log/claude-daemon-autoupdate.log
# shellcheck source=common.sh
. /usr/local/lib/claude-rc/common.sh

CHECK_ONLY=no
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=yes ;;
    *)       echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

DAEMON_LOCK="$CLAUDE_HOME/.claude/daemon.lock"
ROSTER="$CLAUDE_HOME/.claude/daemon/roster.json"
STALE_DAYS=${STALE_DAYS:-7}

command -v jq >/dev/null || { log "jq is not installed; refusing to decide"; exit 1; }

exec 9>/run/claude-daemon-autoupdate.lock
if ! flock -n 9; then
  log "another claude-daemon-autoupdate holds the lock, exiting"
  exit 0
fi

# Field 22 of /proc/<pid>/stat: the start time in clock ticks. The daemon and
# the roster both record it as procStart, which guards against a reused PID.
proc_start() { awk '{sub(/.*\) /, ""); print $20}' "/proc/$1/stat" 2>/dev/null; }

# --- which daemon, on which binary --------------------------------------------
if [ ! -r "$DAEMON_LOCK" ]; then
  log "no $DAEMON_LOCK: no daemon runs; the next client starts one on the launcher's version"
  exit 0
fi
DPID=$(jq -r '.pid // empty' "$DAEMON_LOCK" 2>/dev/null)
DSTART=$(jq -r '.procStart // empty' "$DAEMON_LOCK" 2>/dev/null)
if [ -z "$DPID" ] || [ ! -d "/proc/$DPID" ]; then
  log "$DAEMON_LOCK names pid '${DPID:-?}', which does not run; nothing to stop"
  exit 0
fi
if [ -n "$DSTART" ] && [ "$(proc_start "$DPID")" != "$DSTART" ]; then
  log "pid $DPID is not the daemon in $DAEMON_LOCK (procStart differs); refusing to decide"
  exit 0
fi

# Read the exe, as for the RC server. The `version` field in daemon.lock is what
# the daemon says about itself; /proc says what it executes.
RUNNING_EXE=$(readlink "/proc/$DPID/exe" 2>/dev/null || true)
RUNNING_VER=${RUNNING_EXE##*/}

# Ask the launcher, do not scan versions/. See claude-rc-autoupdate.sh.
SELECTED_VER=$(as_user "$LAUNCHER" --version 2>/dev/null | head -1 | awk '{print $1}')
if [ -z "$SELECTED_VER" ]; then
  log "cannot read a version from '$LAUNCHER --version'; refusing to decide"
  exit 1
fi

log "daemon pid=$DPID running=${RUNNING_VER:-<unknown>} selected=$SELECTED_VER check_only=$CHECK_ONLY"

URGENT=no
case "$RUNNING_EXE" in
  *"(deleted)") REASON="exe is DELETED ($RUNNING_EXE)"; URGENT=yes ;;
  "$VERSIONS"/*)
    if [ "$RUNNING_VER" = "$SELECTED_VER" ]; then
      log "already on the selected version, nothing to do"
      exit 0
    fi
    REASON="running $RUNNING_VER, launcher selects $SELECTED_VER" ;;
  "") log "cannot read /proc/$DPID/exe; refusing to decide"; exit 1 ;;
  *)  REASON="exe is outside $VERSIONS ($RUNNING_EXE)"; URGENT=yes ;;
esac
log "stop wanted: $REASON"

# --- the gate: a live background session blocks ------------------------------
# roster.json lists the claimed workers (sessions), not the idle spares. A spare
# costs nothing to lose. The daemon does not clean the roster when it stops, so
# each entry is checked against /proc, with its procStart.
LIVE=""
if [ -r "$ROSTER" ]; then
  while read -r pid start sid; do
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || continue
    [ -z "$start" ] || [ "$(proc_start "$pid")" = "$start" ] || continue
    LIVE="$LIVE $pid($sid)"
  done < <(jq -r '.workers // {} | to_entries[] | "\(.value.pid) \(.value.procStart // "") \(.value.sessionId // .key)"' "$ROSTER" 2>/dev/null)
fi
LIVE=${LIVE# }
NLIVE=$(printf '%s' "$LIVE" | wc -w)

if [ "$NLIVE" -gt 0 ]; then
  AGE_DAYS=0
  MTIME=$(stat -c %Y "$VERSIONS/$SELECTED_VER" 2>/dev/null || echo 0)
  [ "$MTIME" -gt 0 ] && AGE_DAYS=$(( ( $(date +%s) - MTIME ) / 86400 ))
  log "SKIP: $NLIVE background session(s) live ($LIVE); selected $SELECTED_VER landed ${AGE_DAYS}d ago"
  if [ "$CHECK_ONLY" = no ] && { [ "$URGENT" = yes ] || [ "$AGE_DAYS" -ge "$STALE_DAYS" ]; }; then
    report WARN "Claude bg daemon is $AGE_DAYS days behind on $HOST" \
      "The background-session daemon runs ${RUNNING_VER:-?}, the launcher selects $SELECTED_VER. Background sessions run the daemon's version and can fail with 'does not support this model'.
Blocked by $NLIVE live background session(s): $LIVE
Finish or stop them in 'claude agents', or run as $CLAUDE_USER: claude daemon stop --any
Log: $LOG"
  fi
  exit 0
fi

if [ "$CHECK_ONLY" = yes ]; then
  log "CHECK: would run '$LAUNCHER daemon stop --any --keep-workers' as $CLAUDE_USER now (0 background sessions live)"
  exit 0
fi

# --- act ------------------------------------------------------------------------
# --keep-workers costs nothing with 0 live sessions. For a session that started
# between the gate and the stop, it is the less harmful choice, not a guarantee.
OUT=$(as_user "$LAUNCHER" daemon stop --any --keep-workers 2>&1)
RC=$?
log "daemon stop exit=$RC: $(printf '%s' "$OUT" | tr '\n' ' ')"
for _ in $(seq 1 15); do
  [ -d "/proc/$DPID" ] || break
  sleep 1
done
if [ -d "/proc/$DPID" ]; then
  log "FAIL: daemon pid $DPID still runs 15s after the stop"
  report WARN "Claude bg daemon did not stop on $HOST" \
    "claude daemon stop --any returned $RC but pid $DPID (${RUNNING_VER:-?}) still runs. Background sessions stay on the old version. Log: $LOG"
  exit 1
fi
log "OK: daemon $DPID (${RUNNING_VER:-?}) stopped; the next client starts one on $SELECTED_VER"
exit 0
