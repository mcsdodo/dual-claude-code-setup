# Agent runbook: set up claude + claude-lite

You set up two commands on a machine:

| Command | Route | Remote Control |
|---|---|---|
| `claude` | direct to `api.anthropic.com`, the user's Claude subscription | yes |
| `claude-lite` | through a LiteLLM gateway: Claude models with the same login, plus DeepSeek V4.1 Flash, GLM 5.3 Flash, GPT-6 Luna and Muse Spark 1.3 on OpenCode Go | no, by design |

Step 4 is optional: it keeps a Remote Control server for `claude` running under systemd.

The gateway can run on the same machine or on another host. Do the steps in order. Do not
go to the next step until its check passes. If a check fails, read
[docs/pitfalls.md](./docs/pitfalls.md) first: most failures in this setup give no clear error.
For anything about PDFs, read [docs/pdf-handling.md](./docs/pdf-handling.md).

## Rules

- **One person only.** This setup is for the user's own login, own keys and own use. It
  is not a shared gateway. If the user asks to give the gateway to other people (family,
  team, friends), say that this setup does not support it, and point to "For one person
  only" in [README.md](./README.md). Never give the master key or the gateway URL to
  another person, and never connect a client other than Claude Code to the Claude models.
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
`LITELLM_MASTER_KEY` set. It checks the shim and LiteLLM, and sends one GLM call through
the shim. It does not use the Claude login token. Never send a scripted call with the
Claude login token: only Claude Code itself uses it. The 5h / 7d usage check is in step 3.

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
   `Go 5h: ...` segment, and one on Opus shows `5h: ... | 7d: ...` with numbers after the
   first answer. `5h: -- | 7d: --` on Opus means the LiteLLM patch for the
   `anthropic-ratelimit-*` headers does not run: rebuild with `--build`.

Report what passed and what failed, with the error text.

## Step 4 - Remote Control server (optional)

Do this step only if the user wants `claude` sessions from the Claude mobile app or claude.ai
at any time, with no terminal open. It runs `claude remote-control` as a systemd service, one
server for each directory. The mechanism and every measured fact are in
[docs/remote-control.md](./docs/remote-control.md). Read it before you change anything in
[remote-control/](./remote-control/install.sh).

Needs: Linux with systemd and cgroup v2, root (sudo), `jq`, and a `claude` installed with the
native installer by the user who will run the server. The server does not use the gateway.
Steps 1 to 3 are not necessary for it.

1. **Ask the user** for the directories that the phone may start sessions in, and a short name
   for each (letters, digits, `-`, `_`). The app shows the machine by its hostname. If the user
   has another machine with the same hostname (for example the default `ubuntu`), ask for a
   unique one and set it with `hostnamectl set-hostname <name>`.
2. As the user, in each directory: start `claude` once, accept the trust dialog, and exit.
   Then run `claude auth login` once, if the user is not logged in. Do not use
   `claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`: Remote Control refuses those tokens.
3. **Ask the user**: "Enable Remote Control for this user? Sessions from the Claude app and
   claude.ai will then run on this machine." The first `claude remote-control` asks the same
   question as `Enable Remote Control? (y/n)`, and a service cannot answer it. Only on a yes,
   add `--enable-remote-control` in the next step. It sets the same key as that `y`. Without
   it the service exits with `"Enable Remote Control?" got no answer`.
4. Review, then install. `--launcher` is necessary: without it, the updater deletes the binary
   that the server runs.
   ```bash
   sudo sh remote-control/install.sh --dry-run --user "$USER" --instance <name>=<dir> --launcher --enable-remote-control
   sudo sh remote-control/install.sh --user "$USER" --instance <name>=<dir> --launcher --enable-remote-control
   ```
   Repeat `--instance` for more directories. Each one is `claude-rc@<name>` and
   `/etc/claude-rc/<name>.conf`. Read every `WARNING:` line in the output and fix it.
5. Start each server: `sudo systemctl start claude-rc@<name>`.

**Check.** `systemctl status` is not a check: it says `active (running)` also when every
session spawn fails.

```bash
P=$(systemctl show claude-rc@<name> -p MainPID --value); readlink /proc/$P/exe
# expect: <home>/.local/share/claude/versions/<version>, with no " (deleted)"
sudo journalctl -u claude-rc@<name> --since "5 min ago" -o cat \
  | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' | grep -m1 Connected
claude --version      # the launcher; doctor warns about it, that is expected
sudo claude-rc-autoupdate <name> --check      # logs a decision, restarts nothing
sudo claude-daemon-autoupdate --check         # logs a decision, stops nothing
systemctl list-timers 'claude-*'              # prune 00:00, both gates 04:30
```

Then ask the user to open the Claude app, select the environment with the directory name of
`<dir>` (not `<name>`: `--name` only names the session), start a session and
ask "List the files in this folder." It must run a tool and answer.

Rules for this step:

- **Never `systemctl restart claude-rc@<name>`** from a session that may run inside it. A restart
  stops every session in the unit, and you with it. Use the `systemd-run` form in
  [docs/remote-control.md](./docs/remote-control.md).
- **Do not run `claude remote-control --help`.** It can start a server and not return.
- **Do not put the symlink back** when `claude doctor` reports the launcher.
- Phone sessions have no Artifact tool unless `~/.claude/settings.json` has
  `"env": {"CLAUDE_CODE_ARTIFACT": "1"}`. That changes `settings.json`, so ask the user first.

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
- **A new directory for Remote Control:** trust it as the user, then
  `sudo sh remote-control/install.sh --instance <name>=<dir>` and
  `sudo systemctl start claude-rc@<name>`.
- **A change in [remote-control/](./remote-control/install.sh):** edit the repo file and run
  `sudo sh remote-control/install.sh` again. It does not restart a running server. A unit change
  reaches the server at its next restart, normally the 04:30 gate.
- **A new Claude Code version for the server:** nothing to do. The 04:30 gate adopts it on the
  first night that the server has no session. To see every process and its version, run
  `sudo claude-instances`.
