#!/bin/sh
# claude-lite: Claude Code through the LiteLLM gateway.
#
# Plain `claude` stays direct to api.anthropic.com. This command adds one
# extra settings file with --settings, which MERGES over ~/.claude/settings.json,
# so permissions, hooks, statusline and plugins stay the same in both.
#
# Remote Control does NOT work here, by design: Claude Code refuses it when
# ANTHROPIC_BASE_URL is not api.anthropic.com. Use `claude` for Remote Control.
#
# The settings file must NOT be called settings.json or settings.local.json.
# Claude Code loads those names on its own, and then every `claude` on the
# machine would use the gateway.
set -eu

SETTINGS="${CLAUDE_LITE_SETTINGS:-$HOME/.claude/litellm-settings.json}"

# Use the same binary as `claude`, so both commands update together. Look in
# the native installer's location first, then on PATH (skipping this script).
if [ -x "$HOME/.local/bin/claude" ]; then
  CLAUDE_BIN="$HOME/.local/bin/claude"
else
  CLAUDE_BIN=$(command -v claude || true)
fi
if [ -z "${CLAUDE_BIN:-}" ]; then
  echo "claude-lite: no claude binary found. Install Claude Code first." >&2
  exit 1
fi
if [ ! -r "$SETTINGS" ]; then
  echo "claude-lite: $SETTINGS is missing. Run client/install.sh." >&2
  exit 1
fi

exec "$CLAUDE_BIN" --settings "$SETTINGS" "$@"
