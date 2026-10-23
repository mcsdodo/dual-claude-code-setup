# Pitfalls

Most of these fail with no clear error, or only in an interactive session. Each one was
measured on a running setup. The versions: LiteLLM v1.106.2 (patched, see
[../gateway/patched/README.md](../gateway/patched/README.md)) and Claude Code 2.1.268 to
2.1.309, unless the row says otherwise.

## Client (claude-lite)

| Symptom | Cause | Fix |
|---|---|---|
| Remote Control is not available in `claude-lite` | Claude Code refuses Remote Control when `ANTHROPIC_BASE_URL` is not `api.anthropic.com`. No flag changes this | By design. Use `claude` for Remote Control |
| Remote Control stops for every `claude` on the machine | The gateway env is in `settings.json`, `settings.local.json` or `managed-settings.json`, which Claude Code loads on its own | Keep it only in `~/.claude/litellm-settings.json` |
| A `claude` started from inside `claude-lite` (a script, a background session) also uses the gateway | The settings `env` block is exported to child processes | `env -u ANTHROPIC_BASE_URL -u ANTHROPIC_CUSTOM_HEADERS claude` |
| `/model` shows no gateway models | LiteLLM's `/v1/models` is OpenAI-shaped; Claude Code's discovery wants Anthropic-shaped, so `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` did not add them (tested in `-p` mode only; the template keeps it set, it does no harm) | The `modelPicker` block in the settings file. `/model <name>` works for any gateway name |
| The Claude rows disappear from `/model` | `replaceBuiltInOptions: true` in `modelPicker` | Leave it unset. The Claude models also go through the gateway |
| Some models cannot be selected | `availableModels` is set. It is an allowlist, not a picker list | Do not set it |
| A Go model compacts at 200k tokens | The model is not in Claude Code's catalog, so it assumes 200k | `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000`. It applies only to models outside the catalog, so do not add `behavesAs` to a picker row: that makes the model "known", and the 1M setting can then stop applying (from the binary's text, not measured) |
| Tool search is off | Claude Code turns it off for a base URL that is not Anthropic's | `ENABLE_TOOL_SEARCH=true` |
| `/effort` has no effect on DeepSeek | `/effort` reaches Anthropic models only | One gateway alias per effort (`-none`, `-low`, `-high`, `-max`) |
| A `-p` test passes, every interactive turn on DeepSeek or Muse answers 400 with only `{'model': ...}` | Go refuses a tool schema with a `\0` regex. The built-in `Artifact` tool has one, and it is sent only in interactive sessions with a claude.ai login | The shim removes those patterns for the names in `STRIP_NUL_PATTERN_MODELS`. Always test interactively |

## Gateway

| Symptom | Cause | Fix |
|---|---|---|
| Go answers `400 MissingSessionID` | No `x-opencode-session` header. Claude Code sends `X-Claude-Code-Session-Id`, which `forward_client_headers_to_llm_api` passes on | Keep that setting in `general_settings` (per model it has no effect). A curl or SDK caller must send `x-opencode-session: <id>` itself. Never put a static one in `extra_headers`: it overwrites the client's |
| A Go call hangs about 4 minutes, then 500 `unexpected keyword argument '<field>'` | Claude Code sent a new top-level field that LiteLLM does not know, so `drop_params` misses it. Claude Code retries the 500, so it looks like a slow model | Add the field to `additional_drop_params` on every Go entry. Today: `output_config`, `safeguards` |
| Go 400s on every Claude Code call to DeepSeek or GLM, a curl test passes | The provider prefix is `openai/`, which sends Claude Code's calls to `/v1/responses`. Go does not serve that for these models | Use `custom_openai/`. Never `anthropic/`: it sends the user's Claude login token to opencode.ai |
| Go answers `Model does not support this protocol` | The model is served on `/v1/responses` only (GPT-6 Luna, Muse Spark 1.3) | Use `openai/responses/<id>`. This bridge needs LiteLLM 1.106.2 or later: on 1.83 it sent the model as `responses/<id>` and dropped the session header (`MissingSessionID`) |
| Opus or Sonnet with 1M context fails | `model_name` has a `[1m]` suffix | Keep `model_name` bare. LiteLLM turns `[1m]` into the 1M beta header. Sonnet with `[1m]` was seen to need the extra-usage tier on a Max subscription |
| Auto mode refuses every Bash call: `... is temporarily unavailable (rate-limited)` | The `x-anthropic-billing-header` system block was removed, and Anthropic answers small subscription calls with 429 | Fixed upstream in v1.106; the image build asserts it. Workaround: `claude-lite --permission-mode default` |
| The statusline shows no 5h / 7d usage in `claude-lite` | LiteLLM drops the `anthropic-ratelimit-*` response headers | The client must connect to the shim (port 4001), not to LiteLLM |
| A change to `patched/` or `headers-shim/` has no effect | `docker compose up -d` reuses an image that exists | `docker compose up -d --build` |
| An old LiteLLM image does not start after a rollback | The new version migrated the Postgres schema | `pg_dump` before every bump; restore it to roll back ([../gateway/patched/README.md](../gateway/patched/README.md)) |
| LiteLLM's spend view shows small costs for Claude | Anthropic answers with dated model IDs, which skip the `cost_per_token: 0` override | Ignore. Token counts are correct |

## Models and PDFs

The whole PDF path, and the status per model: [pdf-handling.md](./pdf-handling.md).

| Symptom | Cause | Fix |
|---|---|---|
| DeepSeek on Go: `file must have a file_id or file_data` | Go refuses a PDF `file` part for DeepSeek and has no `/files` endpoint | The shim turns the PDF into page images for the names in `RASTERIZE_PDF_MODELS` |
| GLM on Go: a Claude Code `Read` of a PDF answers 400 `ChatCompletionRequestUserMessageContent` | Measured on LiteLLM v1.83 and v1.106. `glm-5.3-flash` is not in `RASTERIZE_PDF_MODELS`, so the PDF goes to Go as a `file` part. Measured 2026-10-23: a direct `chat/completions` call to Go for `glm-5.3-flash` with a one-page PDF as a `file` part (`file_data`) answered 200 and read the PDF correctly. So Go does not refuse every GLM `file` part; what differs in the Claude Code path is not known | Not fixed. Adding `glm-5.3-flash` to `RASTERIZE_PDF_MODELS` should work, because GLM reads images; this is not tested |
| A non-Anthropic model invents the content of a PDF, or the provider refuses it | Stock LiteLLM sends the PDF as an image URL with a PDF data URI. Older versions (1.83) also dropped a PDF in a tool result with HTTP 200 | The patched image ([../gateway/patched/README.md](../gateway/patched/README.md)) |
| A PDF to Anthropic or Gemini reads worse than expected | Its name was added to `RASTERIZE_PDF_MODELS` | Remove it. Those models read the PDF itself, and better than a picture of it |
| Muse Spark 1.3: every interactive turn answers 400, a `-p` test passes | Muse refuses the Artifact tool's `\0` regex, like DeepSeek. GPT-6 Luna and GLM accept it | `muse-spark-1.3` is in `STRIP_NUL_PATTERN_MODELS` |

## OpenCode Go usage

LiteLLM logs a cost of 0 for Go models. The limit is a usage cap: 20% of the monthly
allowance per 5 hours, 50% per week, 100% per month, for the whole account.
`GET https://opencode.ai/zen/go/v1/usage` with `Authorization: Bearer <OPENCODE_GO_API_KEY>`
returns `rolling`, `weekly` and `monthly`, each with `percent` and `resetsAt`. The endpoint
is not documented and can change. [../client/statusline.py](../client/statusline.py) reads it.

## Policy

Anthropic documents LiteLLM as a supported gateway for Claude Code
([LLM gateway docs](https://code.claude.com/docs/en/llm-gateway)). Read the current terms
of your Claude plan yourself before you use a subscription login through a gateway. Use it
with your own login, for your own use, and keep plain `claude` as the fallback. To roll back, stop using `claude-lite`.
