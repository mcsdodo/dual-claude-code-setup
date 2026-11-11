#!/bin/sh
# Claude Code launcher. It is NOT the native installer's symlink, on purpose.
#
# install.sh --launcher puts this file at ~/.local/bin/claude. Owning that path
# is the documented way to stop the updater's version cleanup:
#   https://code.claude.com/docs/en/setup   ("Update Claude Code" -> "Auto-updates")
#
#   "With a custom launcher, Claude Code also keeps every installed version on
#    disk because it can't tell which version the launcher needs."
#
# That retention is the reason for this file. The updater deletes old binaries
# on a version comparison, and it does not check whether a process executes one.
# Claude Code keeps process.execPath from its start and uses it for every child
# it spawns. So a long-lived process (the Remote Control server) keeps running
# but every new session spawn fails with ENOENT, while `systemctl status` says
# `active (running)`. Measured: 24 hours in that state before anyone saw it.
# A retained version cannot be deleted, so that cannot happen.
# claude-prune-versions does the cleanup instead, and it keeps every version
# that a process executes.
#
# `claude doctor` reports a launcher that the native installer did not create.
# That is EXPECTED. Do not "fix" it by putting the symlink back.
#
# To give control back to the installer:
#   rm ~/.local/bin/claude && curl -fsSL https://claude.ai/install.sh | bash
set -eu

VERSIONS="${HOME:?HOME is not set}/.local/share/claude/versions"

# Real binaries are 248-392 MB. anthropics/claude-code#14791: the updater creates
# a 0-byte placeholder at versions/<version> BEFORE it checks whether another
# Claude process runs, and does not remove it when that check stops the update.
# Not seen on the machine this was measured on, but guarded anyway: a 0-byte file
# sorts newest, every `claude` call would exec it, and this launcher is also the
# recovery path.
#
# The SIZE test is the one that matters. If the placeholder has mode 0755, the
# -x test passes and only the size floor rejects it. Do not merge the checks.
MIN_BYTES=10485760

target=
# sort -Vr, newest first. Version sort is necessary: lexically 2.1.99 ranks
# above 2.1.246. Falls through to the next-newest version if one is unusable.
for v in $(ls -1 "$VERSIONS" 2>/dev/null \
           | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
           | sort -Vr); do
  f="$VERSIONS/$v"
  [ -f "$f" ] || continue
  [ -x "$f" ] || continue
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  [ "$size" -ge "$MIN_BYTES" ] || continue
  target=$f
  break
done

if [ -z "$target" ]; then
  echo "claude: no usable version found in $VERSIONS" >&2
  exit 1
fi

exec "$target" "$@"
