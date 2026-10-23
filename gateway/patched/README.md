# Patched LiteLLM image

[Dockerfile](./Dockerfile) builds `FROM ghcr.io/berriai/litellm:v1.106.2` (digest pinned) and applies three
source patches with [apply_patches.py](./apply_patches.py). The build fails if a patch no longer applies, or if
an upstream fix that this setup depends on is gone.

Run the `docker compose` commands on this page from the `gateway/` folder.

## What the patches change

| File | Change | Why |
|---|---|---|
| `llms/anthropic/pass_through/adapters/transformation.py` | An Anthropic `document` block (top level and inside a tool result) becomes an OpenAI `file` part, not an `image_url` with a `data:application/pdf` URI | Most providers refuse or misread a PDF sent as an image URL |
| `litellm_core_utils/prompt_templates/common_utils.py` | `_is_image_url_part` also matches `file` | Upstream moves media out of a `tool` message into the next `user` message. Without this, a PDF stays in the `tool` message, where some providers turn it into ~200k tokens of base64 text |
| `types/llms/openai.py` | `ChatCompletionAnnotation.type` is `str`, not `Literal["url_citation"]` | A provider that adds a `file` annotation to its answer otherwise gets `500 Invalid response object` after the answer was generated |

These patches matter only for PDFs that Claude Code sends (for example a `Read` of a PDF)
to a non-Anthropic model. The Anthropic models use LiteLLM's native Anthropic path, which
the patches do not touch.

## What the build also asserts (upstream fixes)

The second `RUN` in the [Dockerfile](./Dockerfile) checks four fixes that v1.106.2 has upstream. Older
versions needed patches for them, and this setup breaks without them:

| Upstream fix | Symptom without it |
|---|---|
| The `x-anthropic-billing-header` system block is kept on the Anthropic path | Anthropic answers small subscription calls with 429. Auto mode then refuses every Bash call: `... is temporarily unavailable (rate-limited), so auto mode cannot determine the safety of Bash` |
| Thinking is also sent back as `reasoning_content` | DeepSeek answers 400 now and then: `The reasoning_content in the thinking mode must be passed back to the API` |
| A `ToolSearch` result (`tool_reference` blocks only) becomes an empty `tool` message | After one `ToolSearch` call on a Go model, every turn of the session answers 400 |
| Images are moved out of `tool` messages | Images in tool results are misread by some providers |

## Before a LiteLLM version bump

1. Check the target version against `gh api repos/BerriAI/litellm/security-advisories`.
   Fixes ship per release line, so a newer number is not always safe.
2. `docker compose exec postgres pg_dump -U postgres -Fc litellm > litellm-before-bump.dump`.
   The first start of a new version migrates the schema, and an older image cannot use a
   migrated schema.
3. Change the `FROM` line (tag and digest). Run `docker compose build litellm`. If
   [apply_patches.py](./apply_patches.py) fails, the anchored upstream code moved: update the anchors, never
   delete the check.
4. From `/app`, run `python -c "import litellm; print(litellm.__file__)"` in the new image.
   It must print the venv path. If it does not, the image ships a second copy of
   litellm, and that copy needs the patches too.

## Rolling back a bump

Revert the `FROM` line, rebuild, then restore the dump:

```bash
docker compose stop litellm
docker compose exec -T postgres sh -c 'dropdb -U postgres litellm && createdb -U postgres litellm && pg_restore -U postgres -d litellm --no-owner' < litellm-before-bump.dump
docker compose up -d --build litellm
```

## Check the running server

A healthy container does not prove the patched code runs. Ask the server what it imports:

```bash
docker compose exec litellm python -c "
import importlib.metadata as m, litellm.llms.anthropic.pass_through.adapters.transformation as t
print(m.version('litellm'), hasattr(t.LiteLLMAnthropicMessagesAdapter, '_translate_anthropic_document_to_openai'))"
# expect: 1.106.2 True
```

[apply_patches.py](./apply_patches.py) holds short excerpts of LiteLLM source as anchors. LiteLLM is MIT
licensed; see [NOTICE](../../NOTICE).
