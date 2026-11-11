# Shared setup for the root scripts of the Remote Control server. Sourced, not run.
#
# The caller sets LOG before it sources this file. This file reads
# /etc/claude-rc/host.conf, which names the user that runs Claude Code:
#
#   CLAUDE_USER=alice
#   CLAUDE_HOME=/home/alice
#
# Installed to /usr/local/lib/claude-rc/common.sh by remote-control/install.sh.
# POSIX sh: claude-prune-versions sources it too.

CLAUDE_RC_CONF=${CLAUDE_RC_CONF:-/etc/claude-rc/host.conf}
if [ ! -r "$CLAUDE_RC_CONF" ]; then
  echo "claude-rc: $CLAUDE_RC_CONF is missing. Run remote-control/install.sh." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CLAUDE_RC_CONF"
if [ -z "${CLAUDE_USER:-}" ] || [ -z "${CLAUDE_HOME:-}" ]; then
  echo "claude-rc: CLAUDE_USER and CLAUDE_HOME must be set in $CLAUDE_RC_CONF" >&2
  exit 1
fi

# The launcher and the binaries of the user that runs Claude Code. Not root's:
# these scripts run as root, so $HOME here is /root.
LAUNCHER="$CLAUDE_HOME/.local/bin/claude"
VERSIONS="$CLAUDE_HOME/.local/share/claude/versions"
HOST=$(hostname)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# Run a command as CLAUDE_USER, with that user's HOME. `claude --version` and
# `claude daemon ...` must run as the user: as root they read root's ~/.claude
# and can leave root-owned files in the user's home.
as_user() {
  if [ "$(id -u)" = "$(id -u "$CLAUDE_USER")" ]; then
    HOME="$CLAUDE_HOME" "$@"
  else
    runuser -u "$CLAUDE_USER" -- env HOME="$CLAUDE_HOME" "$@"
  fi
}

# A result or a warning that the user must act on. $1 INFO or WARN, $2 title,
# $3 detail. It goes to the log, and through stdout to the journal of the unit
# that runs the script. Nothing is sent off the machine.
report() { log "$1: $2
$3"; }
