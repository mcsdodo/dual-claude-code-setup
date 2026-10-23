#!/usr/bin/env bash
# Smoke test for the local litellm + headers-shim stack.
#
# What it checks:
#   1. Shim health endpoint returns ok (proves shim is up).
#   2. LiteLLM is reachable through the shim (proves transparent proxying).
#   3. A real /v1/messages call to claude-haiku-4-5 via the shim returns
#      anthropic-ratelimit-* response headers (the actual feature being shipped).
#
# Required env:
#   ANTHROPIC_OAUTH_TOKEN   -- your `sk-ant-oat...` token from `claude /login`.
#                             On Linux: `jq -r '.claudeAiOauth.accessToken'
#                             ~/.claude/.credentials.json`. On macOS Claude Code
#                             keeps it in the Keychain, not in that file.
#   LITELLM_MASTER_KEY      -- the value from gateway/.env.
#   SHIM_URL                -- default http://localhost:4001 (run on the gateway host).
#   SHIM_WAIT               -- seconds to wait for the shim's first refresh,
#                             default 120 (REFRESH_INTERVAL is 45 s).

set -euo pipefail

SHIM_WAIT="${SHIM_WAIT:-120}"
SHIM_URL="${SHIM_URL:-http://localhost:4001}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  red "LITELLM_MASTER_KEY is required (the value from gateway/.env)."
  exit 1
fi

if [[ -z "${ANTHROPIC_OAUTH_TOKEN:-}" ]]; then
  red "ANTHROPIC_OAUTH_TOKEN is required (your sk-ant-oat... bearer)."
  red "Try: export ANTHROPIC_OAUTH_TOKEN=\$(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)"
  red "  or: export ANTHROPIC_OAUTH_TOKEN=\$(python3 -c \"import json,os;print(json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken'])\")"
  exit 1
fi

blue "1/3 shim health"
curl -fsS "${SHIM_URL}/_shim_health" >/dev/null && green "  ok"

blue "2/3 LiteLLM /health/liveliness via shim"
status=$(curl -fsS -o /dev/null -w '%{http_code}' "${SHIM_URL}/health/liveliness" || true)
if [[ "$status" == "200" ]]; then
  green "  ok (200)"
else
  red "  failed (HTTP $status)"
  exit 1
fi

blue "3/3 /v1/messages with claude-haiku-4-5 -- checking for anthropic-ratelimit-* headers"
# The shim's background task fires its own haiku call every REFRESH_INTERVAL
# seconds AFTER seeing the first OAuth bearer in a request. So the FIRST
# request through the shim has no cached headers yet. Send one warmup request,
# then retry every 10 s until the headers appear or SHIM_WAIT runs out.
echo "  warmup request (seeds the bearer for the background task)..."
curl -sS -o /dev/null \
  -X POST "${SHIM_URL}/v1/messages" \
  -H "Authorization: Bearer ${ANTHROPIC_OAUTH_TOKEN}" \
  -H "x-litellm-api-key: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"_"}]}'

hdrs=$(mktemp)
trap 'rm -f "$hdrs"' EXIT
deadline=$(( $(date +%s) + SHIM_WAIT ))
while :; do
  sleep 10
  status=$(curl -sS -o /dev/null -D "$hdrs" -w '%{http_code}' \
    -X POST "${SHIM_URL}/v1/messages" \
    -H "Authorization: Bearer ${ANTHROPIC_OAUTH_TOKEN}" \
    -H "x-litellm-api-key: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"_"}]}')
  if grep -qi '^anthropic-ratelimit-' "$hdrs"; then
    echo "  HTTP $status"
    grep -i '^anthropic-ratelimit-unified' "$hdrs" | sed 's/^/    /' || true
    green "  PASS: ratelimit headers present in response"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "  HTTP $status"
    red "  FAIL: no anthropic-ratelimit-* headers after ${SHIM_WAIT}s -- the shim is not injecting them"
    echo "  Response headers were:"
    sed 's/^/    /' "$hdrs"
    exit 1
  fi
  echo "  no headers yet (HTTP $status), retrying..."
done

green "all checks passed"
