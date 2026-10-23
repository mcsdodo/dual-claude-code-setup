#!/bin/sh
# Install the claude-lite client on Linux or macOS. Idempotent.
#
#   GATEWAY_URL=https://llm-gateway.example.com GATEWAY_KEY=sk-... sh client/install.sh
#
# Options:
#   --dry-run       print what would change, write nothing
#   --statusline    also copy statusline.py to ~/.claude/statusline.py
#
# Environment:
#   GATEWAY_URL     gateway base URL (the shim, port 4001 behind your proxy)
#   GATEWAY_KEY     LITELLM_MASTER_KEY, or a LiteLLM virtual key
#   PREFIX          where claude-lite goes (default: /usr/local/bin as root,
#                   else ~/.local/bin)
#   CLAUDE_LITE_SETTINGS  settings file (default ~/.claude/litellm-settings.json)
#
# What it writes:
#   $PREFIX/claude-lite                    mode 0755
#   ~/.claude/litellm-settings.json        mode 0600. The `env` keys and
#                                          `modelPicker` come from
#                                          litellm-settings.example.json; any
#                                          other key you added stays.
# It never touches ~/.claude/settings.json.
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
DRY=0
STATUSLINE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --statusline) STATUSLINE=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" = "0" ]; then DEFAULT_PREFIX=/usr/local/bin; else DEFAULT_PREFIX="$HOME/.local/bin"; fi
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
SETTINGS="${CLAUDE_LITE_SETTINGS:-$HOME/.claude/litellm-settings.json}"

case "$(basename "$SETTINGS")" in
  settings.json|settings.local.json)
    echo "refusing: $SETTINGS is a name Claude Code loads on its own. Every claude on" >&2
    echo "the machine would then use the gateway and lose Remote Control." >&2
    exit 1 ;;
esac

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

if [ -z "${GATEWAY_URL:-}" ] || [ -z "${GATEWAY_KEY:-}" ]; then
  if [ ! -f "$SETTINGS" ]; then
    echo "GATEWAY_URL and GATEWAY_KEY are required for a first install." >&2
    exit 1
  fi
  echo "GATEWAY_URL / GATEWAY_KEY not set: keeping the values already in $SETTINGS"
fi

run() { if [ "$DRY" = 1 ]; then echo "would run: $*"; else "$@"; fi; }

echo "==> claude-lite -> $PREFIX/claude-lite"
run mkdir -p "$PREFIX"
run install -m 0755 "$SRC/claude-lite.sh" "$PREFIX/claude-lite"

echo "==> settings -> $SETTINGS"
DRY="$DRY" TEMPLATE="$SRC/litellm-settings.example.json" SETTINGS="$SETTINGS" \
GATEWAY_URL="${GATEWAY_URL:-}" GATEWAY_KEY="${GATEWAY_KEY:-}" python3 - <<'EOF'
import json, os, sys, tempfile

template = json.load(open(os.environ["TEMPLATE"], encoding="utf-8"))
path = os.environ["SETTINGS"]
current = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        current = json.load(fh)

env = dict(current.get("env", {}))
for k, v in template["env"].items():
    if k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS") and k in env:
        continue  # keep the real values; replaced below only when given
    env[k] = v
if os.environ["GATEWAY_URL"]:
    env["ANTHROPIC_BASE_URL"] = os.environ["GATEWAY_URL"].rstrip("/")
if os.environ["GATEWAY_KEY"]:
    env["ANTHROPIC_CUSTOM_HEADERS"] = "x-litellm-api-key: Bearer " + os.environ["GATEWAY_KEY"]
if "<" in env.get("ANTHROPIC_BASE_URL", "") + env.get("ANTHROPIC_CUSTOM_HEADERS", "") \
        or "example.com" in env.get("ANTHROPIC_BASE_URL", ""):
    sys.exit("settings still hold template placeholders: set GATEWAY_URL and GATEWAY_KEY")

current["env"] = env
current["modelPicker"] = template["modelPicker"]
out = json.dumps(current, indent=2) + "\n"

if os.environ["DRY"] == "1":
    shown = json.loads(out)
    shown["env"]["ANTHROPIC_CUSTOM_HEADERS"] = "x-litellm-api-key: Bearer <redacted>"
    print("would write:\n" + json.dumps(shown, indent=2))
    sys.exit(0)

d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".litellm-settings.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(out)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("    written, mode 0600")
EOF

if [ "$STATUSLINE" = 1 ]; then
  echo "==> statusline -> $HOME/.claude/statusline.py"
  run install -m 0644 "$SRC/statusline.py" "$HOME/.claude/statusline.py"
  cat <<'MSG'
    To enable it, add this to ~/.claude/settings.json (it applies to claude and claude-lite):
      "statusLine": { "type": "command", "command": "python3 ~/.claude/statusline.py" }
    For the OpenCode Go quota segment, put your Go API key in ~/.claude/opencode-go.key (mode 0600).
MSG
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "note: $PREFIX is not on PATH" ;;
esac
echo "==> done. Next: run the checks in CLAUDE.md, step 3."
