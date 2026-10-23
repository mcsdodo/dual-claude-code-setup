# dual-claude-code-setup

Two Claude Code commands on one machine:

- **`claude`**: unchanged. Direct to Anthropic with your Claude subscription. Remote Control works.
- **`claude-lite`**: the same Claude Code, the same login, permissions, hooks and plugins,
  but through a self-hosted [LiteLLM](https://github.com/BerriAI/litellm) gateway. It adds
  DeepSeek V4.1 Flash and GLM 5.3 Flash on an [OpenCode Go](https://opencode.ai/docs/go)
  subscription, listed in the `/model` picker next to Opus, Sonnet and Haiku.

```
claude       ---------------------------------------------> api.anthropic.com
claude-lite  --> HTTPS proxy --> headers shim :4001 --> LiteLLM --+--> api.anthropic.com  (your login token)
                                                                  +--> opencode.ai Go      (Go API key)
```

## Set it up

Give this folder to a coding agent and ask it to follow [CLAUDE.md](./CLAUDE.md). It has
the steps and a check after each one. To do it by hand, follow the same file.

## What is in it

| Path | What |
|---|---|
| [CLAUDE.md](./CLAUDE.md) | The setup runbook: gateway, client, verification |
| [gateway/docker-compose.yml](./gateway/docker-compose.yml) | Postgres, patched LiteLLM, headers shim |
| [gateway/config.yaml](./gateway/config.yaml) | The models: 3 Claude, 4 DeepSeek effort aliases, GLM |
| [gateway/patched/](./gateway/patched/README.md) | LiteLLM v1.106.2 with three source patches, and build-time checks |
| [gateway/headers-shim/](./gateway/headers-shim/server.py) | Restores the subscription usage headers, turns PDFs into images for DeepSeek, removes a tool-schema regex that Go refuses |
| [gateway/smoke.sh](./gateway/smoke.sh) | Checks that the shim restores the usage headers |
| [client/](./client/install.sh) | `claude-lite` wrappers (sh, PowerShell), the settings template, the installer, an optional statusline |
| [docs/pitfalls.md](./docs/pitfalls.md) | Symptom, cause and fix for each known trap |

## Models

| `/model` name | Picker row | Provider |
|---|---|---|
| `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5` | built-in Opus, Sonnet, Haiku | Anthropic, your subscription |
| `deepseek-v4.1-flash-high` | DeepSeek High | OpenCode Go |
| `glm-5.3-flash` | GLM 5.3 Flash | OpenCode Go |
| `deepseek-v4.1-flash-none`, `-low`, `-max` | none: type `/model <name>` | OpenCode Go |

## Requirements

- Claude Code, logged in with a Claude Pro or Max account (or an Anthropic API key).
- A Docker host for the gateway, and an HTTPS reverse proxy on your LAN or VPN. Do not
  expose the gateway to the internet: it forwards your Claude login token.
- An OpenCode Go subscription and API key.
- Linux or macOS for the installer. Windows works with
  [client/claude-lite.ps1](./client/claude-lite.ps1) and a manual settings file.

## Limits

- Remote Control does not work in `claude-lite`. That is Claude Code's rule for any
  non-Anthropic base URL.
- Go models that only serve `/v1/responses` (GPT 6 Luna, Muse Spark) are not included. See
  [docs/pitfalls.md](./docs/pitfalls.md).
