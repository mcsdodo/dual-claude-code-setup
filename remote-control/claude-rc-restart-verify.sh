#!/bin/bash
# Restart a claude-rc@ instance onto the newest installed Claude Code version,
# then PROVE that it came back. Logs the result as a RESULT: line.
#
#   claude-rc-restart-verify <instance> [<expected version>]
#
# Why a script and not `systemctl restart`:
#
#   1. A session that wants the restart is often inside the target.
#      KillMode=control-group, and the Remote Control server is the parent of
#      every session it spawns. So a session that runs in claude-rc@<name> cannot
#      restart its own unit and then check the result. Start this script
#      detached, as a transient unit that belongs to PID 1:
#
#        systemd-run --unit=claude-rc-restart --on-active=90 --collect \
#          --property=Type=oneshot --property=TimeoutStartSec=600 \
#          /usr/local/sbin/claude-rc-restart-verify <instance>
#
#      TimeoutStartSec=600 is necessary: a transient oneshot gets the 90 s
#      manager default, and this script can take about 5 minutes.
#      --on-active=90 gives the calling session time to send its last message.
#
#   2. `systemctl status` is not verification. The unit was seen to read
#      `active (running)` for 24 hours while every session spawn failed with
#      ENOENT. So ActiveState is not a success test below. The tests are: the
#      MainPID changed, its exe is a real file with no " (deleted)" suffix, a new
#      `claude --version` works, and the server logged `Connected`.
set -uo pipefail

LOG=/var/log/claude-rc-restart-verify.log
# shellcheck source=common.sh
. /usr/local/lib/claude-rc/common.sh

INSTANCE=${1:-}
EXPECT=${2:-}
[ -n "$INSTANCE" ] || { echo "usage: claude-rc-restart-verify <instance> [<expected version>]" >&2; exit 2; }
UNIT="claude-rc@${INSTANCE}.service"
WAIT_SECS=${WAIT_SECS:-150}

# The exe of a pid, "" if unknown. readlink appends " (deleted)" when the binary
# was unlinked under the process. That is the failure to detect, so keep it.
exe_of() { readlink "/proc/$1/exe" 2>/dev/null || true; }
main_pid() { systemctl show "$UNIT" -p MainPID --value 2>/dev/null || echo 0; }

log "=============================================================="
log "restart+verify $UNIT (expect=${EXPECT:-<newest>})"

OLD_PID=$(main_pid)
OLD_EXE=$(exe_of "$OLD_PID")
log "before: MainPID=$OLD_PID exe=${OLD_EXE:-<none>}"
log "before: launcher would select $(as_user "$LAUNCHER" --version 2>&1 | head -1)"

SINCE=$(date '+%Y-%m-%d %H:%M:%S')
sleep 1

log "restarting $UNIT ..."
systemctl restart "$UNIT"
RC=$?
log "systemctl restart exit=$RC"

# Wait for a NEW MainPID that runs.
NEW_PID=0
for _ in $(seq 1 "$WAIT_SECS"); do
  NEW_PID=$(main_pid)
  if [ "$NEW_PID" != "0" ] && [ "$NEW_PID" != "$OLD_PID" ] && [ -d "/proc/$NEW_PID" ]; then
    break
  fi
  sleep 1
done

STATUS=OK
PROBLEMS=""
fail()   { STATUS=FAIL;                           PROBLEMS="${PROBLEMS}- $1"$'\n'; log "FAIL: $1"; }
degrade(){ [ "$STATUS" = OK ] && STATUS=DEGRADED; PROBLEMS="${PROBLEMS}- $1"$'\n'; log "WARN: $1"; }

# --- check 1: the MainPID changed -------------------------------------------
if [ "$NEW_PID" = "0" ] || [ ! -d "/proc/$NEW_PID" ]; then
  fail "no running MainPID after ${WAIT_SECS}s (got '$NEW_PID')"
elif [ "$NEW_PID" = "$OLD_PID" ]; then
  fail "MainPID unchanged ($NEW_PID): the unit did not restart"
else
  log "after: MainPID=$NEW_PID (was $OLD_PID)"
fi

# --- check 2: its exe is a real binary that exists --------------------------
NEW_EXE=$(exe_of "$NEW_PID")
LANDED=""
log "after: exe=${NEW_EXE:-<none>}"
case "$NEW_EXE" in
  "")            fail "cannot read /proc/$NEW_PID/exe" ;;
  *"(deleted)")  fail "exe is DELETED ($NEW_EXE): the deleted-binary bug is back" ;;
  "$VERSIONS"/*) LANDED=${NEW_EXE##*/}
                 [ -f "$NEW_EXE" ] || fail "exe path does not exist on disk: $NEW_EXE"
                 log "landed on version: $LANDED" ;;
  *)             degrade "exe is outside $VERSIONS: $NEW_EXE" ;;
esac

# --- check 3: did it land on the expected version ---------------------------
# Not fatal: the launcher falls through to the next-newest usable binary on
# purpose, so a rejected build still gives a working service. It is a warning
# because a rejected build is what you want to know about.
#
# Only an OLDER landing is a fallthrough. A NEWER one means that a release
# landed after the caller chose EXPECT (measured: 7 s before a restart).
if [ -n "$EXPECT" ] && [ -n "$LANDED" ] && [ "$LANDED" != "$EXPECT" ]; then
  if [ "$(printf '%s\n%s\n' "$LANDED" "$EXPECT" | sort -V | tail -1)" = "$LANDED" ]; then
    log "landed on $LANDED, newer than the expected $EXPECT: a release landed after the caller chose, not a fallthrough"
  else
    degrade "expected $EXPECT but landed on $LANDED (the launcher fell through: is $EXPECT a bad binary?)"
  fi
fi

# --- check 4: claude can start: a new exec, not the old process --------------
CLI_OUT=$(as_user "$LAUNCHER" --version 2>&1)
CLI_RC=$?
CLI_VER=$(printf '%s' "$CLI_OUT" | head -1)
if [ "$CLI_RC" -ne 0 ] || [ -z "$CLI_VER" ]; then
  fail "'$LAUNCHER --version' exit=$CLI_RC output: ${CLI_OUT:-<empty>}"
else
  log "callable: $LAUNCHER --version -> $CLI_VER"
fi

# --- check 5: the server connected again ------------------------------------
# The TUI status block has ANSI codes; remove them before grep. The startup
# lines pass LogRateLimitBurst=50, so this marker is reliable.
CONNECTED=no
for _ in $(seq 1 60); do
  if journalctl -u "$UNIT" --since "$SINCE" --no-pager -o cat 2>/dev/null \
     | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' \
     | grep -q 'Connected'; then
    CONNECTED=yes; break
  fi
  sleep 2
done
if [ "$CONNECTED" = yes ]; then
  log "server logged 'Connected'"
else
  fail "server never logged 'Connected' within 120s"
fi

# --- report -----------------------------------------------------------------
JOURNAL=$(journalctl -u "$UNIT" --since "$SINCE" --no-pager -o cat 2>/dev/null \
          | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' \
          | grep -v '^[[:space:]]*$' | tail -25)

log "RESULT: $STATUS"
[ -n "$PROBLEMS" ] && log "problems:"$'\n'"$PROBLEMS"
log "journal since restart:"$'\n'"$JOURNAL"

case "$STATUS" in
  OK)       report INFO "Claude RC updated OK on $HOST" \
              "$UNIT restarted onto $LANDED (was ${OLD_EXE##*/}). CLI: $CLI_VER. Server connected. Log: $LOG" ;;
  DEGRADED) report WARN "Claude RC restarted DEGRADED on $HOST" \
              "$UNIT runs on ${LANDED:-?} but not as expected.
$PROBLEMS
Log: $LOG" ;;
  FAIL)     report WARN "Claude RC restart FAILED on $HOST" \
              "$UNIT did NOT come back cleanly.
$PROBLEMS
Restart=always/RestartSec=15 still tries again. Journal:
$JOURNAL

Log: $LOG" ;;
esac

[ "$STATUS" = FAIL ] && exit 1
exit 0
