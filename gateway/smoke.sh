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
#                             Easiest source: `cat ~/.claude/.credentials.json |
#                             jq -r '.claudeAiOauth.accessToken'`.
#   LITELLM_MASTER_KEY      -- defaults to sk-local-master-key (matches .env.example).

set -euo pipefail

LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-master-key}"
SHIM_URL="${SHIM_URL:-http://localhost:4001}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

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
# request through the shim won't have cached headers yet. We send one warmup
# request, wait one refresh cycle, then check.
echo "  warmup request (seeds the bearer for the background task)..."
curl -sS -o /dev/null \
  -X POST "${SHIM_URL}/v1/messages" \
  -H "Authorization: Bearer ${ANTHROPIC_OAUTH_TOKEN}" \
  -H "x-litellm-api-key: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"_"}]}'

echo "  waiting 12s for background refresh to populate cache..."
sleep 12

echo "  test request (headers should now be merged)..."
tmp=$(mktemp)
status=$(curl -sS -o "$tmp" -D - -w '%{http_code}' \
  -X POST "${SHIM_URL}/v1/messages" \
  -H "Authorization: Bearer ${ANTHROPIC_OAUTH_TOKEN}" \
  -H "x-litellm-api-key: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"_"}]}' \
  | tee /tmp/shim-response-headers.txt | tail -1)

echo "  HTTP $status"
echo "  --- response headers (anthropic-* only) ---"
grep -i '^anthropic-' /tmp/shim-response-headers.txt | sed 's/^/    /' || true

if grep -qi '^anthropic-ratelimit-' /tmp/shim-response-headers.txt; then
  green "  PASS: ratelimit headers present in response"
else
  red "  FAIL: no anthropic-ratelimit-* headers in response -- shim is not injecting them"
  echo
  echo "  Full response headers were:"
  cat /tmp/shim-response-headers.txt | sed 's/^/    /'
  exit 1
fi

rm -f "$tmp"
green "all checks passed"
