#!/bin/sh
# Prune unused Claude Code versions. Run daily by claude-prune-versions.timer.
#
# Needed because the launcher at ~/.local/bin/claude turns off the updater's own
# cleanup, on purpose (see claude-launcher.sh). Without this the versions folder
# grows by about 325 MB per release.
#
# Keeps:
#   * the newest KEEP_NEWEST VALID versions
#   * every version that a live process executes
# Deletes all other files, invalid ones too (see below).
#
# The in-use check is the mechanism, not a courtesy. After newer releases land,
# ONLY the in-use check protects the version that a long-running server started
# on: keep-newest has moved past it. Without this check the deleted-binary bug
# comes back.
#
# Reference-based ON PURPOSE. A "delete anything older than N days" rule would
# have deleted a binary under week-old session processes.
#
#   DRY_RUN=1 claude-prune-versions        # show what would go, change nothing
#   KEEP_NEWEST=3 claude-prune-versions    # keep more
set -eu

LOG=/var/log/claude-prune-versions.log
# shellcheck source=common.sh
. /usr/local/lib/claude-rc/common.sh

KEEP_NEWEST=${KEEP_NEWEST:-2}
DRY_RUN=${DRY_RUN:-0}
VERBOSE=${VERBOSE:-0}

# See claude-launcher.sh. A 0-byte placeholder (anthropics/claude-code#14791)
# sorts newest, so without this it would take a keep-newest slot and push a
# real, working version out of the keep set. Invalid files are junk: they are
# deleted, unless a process executes them.
MIN_BYTES=10485760

[ -d "$VERSIONS" ] || { echo "prune: $VERSIONS does not exist" >&2; exit 1; }

names=$(ls -1 "$VERSIONS" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)
[ -n "$names" ] || exit 0

valid=''
for v in $names; do
  f="$VERSIONS/$v"
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ -f "$f" ] && [ -x "$f" ] && [ "$size" -ge "$MIN_BYTES" ]; then
    valid="$valid$v
"
  fi
done

# Keep-newest counts VALID versions only.
keep_newest=$(printf '%s' "$valid" | grep -v '^$' | tail -n "$KEEP_NEWEST" || true)

# Every version that a live process executes. This must run as root to see the
# processes of every user. readlink appends " (deleted)" when the target is
# already unlinked; remove it so those still count as in use.
in_use=$(for e in /proc/[0-9]*/exe; do readlink "$e" 2>/dev/null || true; done \
         | sed -e 's/ (deleted)$//' \
         | grep -E "^$VERSIONS/[0-9]+\.[0-9]+\.[0-9]+$" \
         | sed -e "s#^$VERSIONS/##" \
         | sort -u || true)

keep=$(printf '%s\n%s\n' "$keep_newest" "$in_use" | grep -v '^$' | sort -u)

if [ "$VERBOSE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
  echo "-- present:  $(echo $names)"
  echo "-- valid:    $(echo $valid)"
  echo "-- newest$KEEP_NEWEST:  $(echo $keep_newest)"
  echo "-- in use:   $(echo $in_use)"
  echo "-- keeping:  $(echo $keep)"
fi

for v in $names; do
  if printf '%s\n' "$keep" | grep -qx "$v"; then
    continue
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "would delete $VERSIONS/$v"
  else
    log "deleting $VERSIONS/$v"
    rm -f "$VERSIONS/$v"
  fi
done
