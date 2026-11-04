#!/usr/bin/env bash
# Smoke test for the local litellm + headers-shim stack.
#
# What it checks:
#   1. The shim health endpoint returns ok (the shim is up).
#   2. LiteLLM answers through the shim (the shim proxies).
#   3. A GLM 5.3 Flash call on /v1/messages through the shim answers 200 with a
#      message (the Anthropic-shaped path to OpenCode Go works).
#
# It does NOT use your Claude login token, and it must not. Only Claude Code
# itself sends calls with that token. The Claude models and the 5h / 7d usage
# headers are checked with a real claude-lite session (CLAUDE.md, step 3).
#
# Required env:
#   LITELLM_MASTER_KEY      -- the value from gateway/.env.
#   SHIM_URL                -- default http://localhost:4001 (run on the gateway host).

set -euo pipefail

SHIM_URL="${SHIM_URL:-http://localhost:4001}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  red "LITELLM_MASTER_KEY is required (the value from gateway/.env)."
  exit 1
fi

blue "1/3 shim health"
curl -fsS "${SHIM_URL}/_shim_health" >/dev/null && green "  ok"

blue "2/3 LiteLLM /health/liveliness via shim"
status=$(curl -sS -o /dev/null -w '%{http_code}' "${SHIM_URL}/health/liveliness" || true)
if [[ "$status" == "200" ]]; then
  green "  ok (200)"
else
  red "  failed (HTTP $status)"
  exit 1
fi

blue "3/3 /v1/messages with glm-5.3-flash via shim"
body=$(mktemp)
trap 'rm -f "$body"' EXIT
status=$(curl -sS -o "$body" -w '%{http_code}' \
  -X POST "${SHIM_URL}/v1/messages" \
  -H "x-litellm-api-key: Bearer ${LITELLM_MASTER_KEY}" \
  -H "x-opencode-session: smoke-check" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"glm-5.3-flash","max_tokens":256,"messages":[{"role":"user","content":"Reply with ok."}]}' || true)
if [[ "$status" == "200" ]] && grep -q '"content"' "$body"; then
  green "  ok (200)"
else
  red "  failed (HTTP $status)"
  sed 's/^/    /' "$body" | head -c 2000
  echo
  exit 1
fi

green "all checks passed"
