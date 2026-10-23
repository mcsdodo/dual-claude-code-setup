# Agent runbook: set up claude + claude-lite

You set up two commands on a machine:

| Command | Route | Remote Control |
|---|---|---|
| `claude` | direct to `api.anthropic.com`, the user's Claude subscription | yes |
| `claude-lite` | through a LiteLLM gateway: Claude models with the same login, plus DeepSeek V4.1 Flash, GLM 5.3 Flash, GPT-6 Luna and Muse Spark 1.3 on OpenCode Go | no, by design |

The gateway can run on the same machine or on another host. Do the steps in order. Do not
go to the next step until its check passes. If a check fails, read
[docs/pitfalls.md](./docs/pitfalls.md) first: most failures in this setup give no clear error.
For anything about PDFs, read [docs/pdf-handling.md](./docs/pdf-handling.md).

## Rules

- **Never put the gateway env in an auto-loaded settings file.** Claude Code loads
  `settings.json` and `settings.local.json` on its own (in `~/.claude/` and in each
  project's `.claude/`), and `managed-settings.json`. The gateway env there moves every
  `claude` on the machine to the gateway and stops Remote Control. The gateway env goes
  only in `~/.claude/litellm-settings.json`, which only `claude-lite` loads.
- **Do not change `~/.claude/settings.json`** unless the user asks. The statusline is the
  only optional change there.
- **Ask the user** for the gateway's HTTPS URL, and for the OpenCode Go API key. Never
  invent them, and never print a key in full.
- **Test interactive sessions, not only `-p`.** `-p` mode sends fewer tools, so a `-p` test
  can pass while every interactive turn fails.
- Write secrets only to `gateway/.env` and `~/.claude/litellm-settings.json`, both mode `0600`.
  The one exception is the optional statusline key, `~/.claude/opencode-go.key` (mode `0600`).
- Run every command from the repo root unless the step says otherwise.

## Step 1 - the gateway

Needs: Docker with the Compose plugin, an HTTPS reverse proxy (Caddy, Traefik, nginx) that
can reach port 4001 on this host, and an OpenCode Go subscription.

1. Create the secrets file:
   ```bash
   cp gateway/.env.example gateway/.env && chmod 600 gateway/.env
   ```
   Set `LITELLM_MASTER_KEY` (`openssl rand -hex 24`, with an `sk-` prefix),
   `LITELLM_DB_PASSWORD` (random) and `OPENCODE_GO_API_KEY` (from the user).
2. Start it. Always pass `--build`:
   ```bash
   docker compose -f gateway/docker-compose.yml up -d --build
   docker compose -f gateway/docker-compose.yml ps   # postgres, litellm, litellm-headers-shim: healthy
   ```
   The first build takes a few minutes. It fails on purpose if a patch no longer applies;
   see [gateway/patched/README.md](./gateway/patched/README.md).
3. Point the reverse proxy at `<this host>:4001` (the shim, **not** LiteLLM). Keep it on the
   LAN or a VPN: the gateway forwards the user's Claude login token.

**Check** (set `GW` to the HTTPS URL and `KEY` to the master key):

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$GW/health/liveliness"   # 200
curl -s "$GW/v1/models" -H "Authorization: Bearer $KEY" | python3 -c "import json,sys;print([m['id'] for m in json.load(sys.stdin)['data']])"
# expect: claude-opus-5, claude-sonnet-5, claude-haiku-4-5, deepseek-v4.1-flash-none/-low/-high/-max,
#         glm-5.3-flash, gpt-6-luna, muse-spark-1.3
curl -s "$GW/v1/chat/completions" -H "Authorization: Bearer $KEY" \
  -H "x-opencode-session: setup-check" -H "Content-Type: application/json" \
  -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"Reply with ok."}]}'
```

The last call must answer with a message. `MissingSessionID` means the session header did
not arrive.

On the gateway host, also run [gateway/smoke.sh](./gateway/smoke.sh) with
`LITELLM_MASTER_KEY` and `ANTHROPIC_OAUTH_TOKEN` set. It checks that the shim restores the
subscription usage headers. It can take up to 2 minutes.

## Step 2 - the client

Needs: Claude Code installed (`claude --version`) and logged in with the user's account
(`claude /login`, once). `claude-lite` uses the same login.

**Linux or macOS:**

```bash
GATEWAY_URL="$GW" GATEWAY_KEY="$KEY" sh client/install.sh --dry-run   # review
GATEWAY_URL="$GW" GATEWAY_KEY="$KEY" sh client/install.sh
```

It installs `claude-lite` (to `/usr/local/bin` as root, else `~/.local/bin`) and writes
`~/.claude/litellm-settings.json` from
[client/litellm-settings.example.json](./client/litellm-settings.example.json).
Add `--statusline` if the user wants the quota statusline
([client/statusline.py](./client/statusline.py)); the installer prints the one line for
`settings.json`.

**Windows:** copy [client/litellm-settings.example.json](./client/litellm-settings.example.json)
to `%USERPROFILE%\.claude\litellm-settings.json`, put in the URL and key, and copy
[client/claude-lite.ps1](./client/claude-lite.ps1) to a folder on `PATH`.

## Step 3 - verify

Do all of these. A reply alone does not prove the route.

1. Claude through the gateway, with the login token:
   `claude-lite --model claude-haiku-4-5 -p "Reply with ok."`
2. A Go model, non-interactive:
   `claude-lite --model deepseek-v4.1-flash-high -p "Reply with ok."`
3. **Interactive** (start `claude-lite`, then type in the session). If you cannot drive an
   interactive terminal (for example with `tmux send-keys`), ask the user to do this step
   and report what they see:
   - `/model` lists **DeepSeek High**, **GLM 5.3 Flash**, **GPT-6 Luna** and
     **Muse Spark 1.3** after the built-in Opus, Sonnet and Haiku rows.
   - Select each of the four, press `s` (this session only), and ask "List the files in
     this folder." Each must run a tool and answer. Muse fails here with a 400 if it is
     missing from `STRIP_NUL_PATTERN_MODELS`.
   - Do the same on DeepSeek High, then ask "Use ToolSearch to find the cron tools, then
     list cron jobs." The turn after the `ToolSearch` call must not fail.
4. The two commands differ: `claude doctor` reports Remote Control as available, and
   `claude-lite doctor` reports that it is not.
5. On the gateway host, `docker compose -f gateway/docker-compose.yml logs litellm --since 10m` shows the calls, and no
   `unexpected keyword argument` and no 400s.
6. If the user enabled the statusline: a `claude-lite` session on DeepSeek shows a
   `Go 5h: ...` segment, and one on Opus shows `5h: ... | 7d: ...`.

Report what passed and what failed, with the error text.

## Later changes

- **A new Claude Code release** can add a top-level request field. The symptom: a Go call
  hangs about 4 minutes, then fails with 500. Find the field with
  `docker compose -f gateway/docker-compose.yml logs litellm | grep "unexpected keyword argument"`, add it to
  `additional_drop_params` on every Go entry in [gateway/config.yaml](./gateway/config.yaml),
  and run `docker compose -f gateway/docker-compose.yml up -d --build`.
- **A new model:** add an entry to [gateway/config.yaml](./gateway/config.yaml). Copy a
  `custom_openai/` entry if Go serves the model on chat completions, or an
  `openai/responses/` entry if Go answers `Model does not support this protocol`. Test it
  interactively; add it to `STRIP_NUL_PATTERN_MODELS` in
  [gateway/docker-compose.yml](./gateway/docker-compose.yml) only if a turn answers 400,
  and to `RASTERIZE_PDF_MODELS` only if a PDF `Read` fails on a `file` part. Add a picker
  row in the settings template and the user's settings file. Add it to `GO_MODEL_MARKERS` in
  [client/statusline.py](./client/statusline.py). Then do step 3 again.
- **A LiteLLM version bump:** follow [gateway/patched/README.md](./gateway/patched/README.md).
  Take a `pg_dump` first.
