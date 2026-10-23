# How a PDF gets to each model

A PDF is the one input that takes a different path for almost every model in this setup.
This page explains the path, why each part exists, and what was measured.

## The problem in one paragraph

When Claude Code reads a PDF (the `Read` tool, or a PDF you attach), it sends an Anthropic
`document` block: the whole file, base64, `media_type: application/pdf`. For a `Read` the
block sits **inside a `tool_result`**. Anthropic models read that block natively. Every other
model needs LiteLLM to translate it to an OpenAI-style message, and the providers do not
agree on what a PDF looks like in that format. **The worst failure is silent**: the call
answers HTTP 200, the PDF never reached the model, and the model writes a confident answer
from the prompt alone. On a document task that answer is complete, well formed and
invented. LiteLLM 1.83 did this for every PDF in a tool result; 1.106 carries the PDF but
in the wrong shape, which some providers refuse and some misread.

## The path

```
Claude Code Read(pdf)
  -> Anthropic `document` block inside a tool_result
  -> headers shim (:4001)
       model in RASTERIZE_PDF_MODELS?  yes -> pdftoppm: each page -> JPEG `image` block
                                       no  -> unchanged
  -> LiteLLM
       Anthropic model?  yes -> native Anthropic path, the document goes as it is
                         no  -> adapter: `document` -> OpenAI `file` part   (patch 1)
                                media moved out of the `tool` message
                                into the next `user` message                (patch 2)
  -> provider
```

| Step | What it does | Why |
|---|---|---|
| Shim: rasterize | For the models in `RASTERIZE_PDF_MODELS`, it turns each PDF `document` block into one JPEG `image` block per page, before LiteLLM sees the body | OpenCode Go refuses a PDF `file` part for DeepSeek, and it has no `/files` endpoint to upload one. It accepts images |
| Patch 1: `document` -> `file` part | Stock LiteLLM sends a PDF as `image_url` with a `data:application/pdf;base64,...` URI. The patch sends an OpenAI `file` part | A PDF in an image URL is not a shape that OpenAI defines. Some providers guess it right, Z.AI answers `Could not decode image` |
| Patch 2: move the `file` part out of the `tool` message | Upstream already moves images out of a `tool` message into the next `user` message. The patch makes it move `file` parts too | The OpenAI chat format allows only text in a `tool` message. One provider turned a PDF there into about 200,000 tokens of base64 text |
| Patch 3: annotation type | `ChatCompletionAnnotation.type` accepts any string | A provider that parses the PDF can add a `file` annotation to its answer. Stock LiteLLM then fails with `500 Invalid response object`, after the answer was generated and paid for |
| Shim: body size | It accepts request bodies up to 32 MiB (`MAX_BODY_BYTES`) | The aiohttp default is 1 MiB. One scanned PDF is about 1.1 MB in base64, so the default answered 413 |

The patches are in [../gateway/patched/apply_patches.py](../gateway/patched/apply_patches.py),
and the shim code is in [../gateway/headers-shim/server.py](../gateway/headers-shim/server.py).

## Status per model

| Model | Path | Result of a Claude Code PDF `Read` |
|---|---|---|
| `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5` | Native Anthropic. No shim change, no patch | Works. The model reads the PDF itself |
| `deepseek-v4.1-flash-low`, `-high`, `-max` | Shim turns pages into JPEGs, LiteLLM sends images | Works. Without the shim Go answers 400 `file must have a file_id or file_data` |
| `deepseek-v4.1-flash-none` | Not in `RASTERIZE_PDF_MODELS`, so the PDF goes as a `file` part | Not tested. Expect the same 400 as the other DeepSeek aliases without the shim. Add the name to the list if you read PDFs on this alias |
| `gpt-6-luna`, `muse-spark-1.3` | Not rasterized. LiteLLM's Responses API bridge carries the PDF | Works (tested on LiteLLM 1.106.2) |
| `glm-5.3-flash` | `file` part through LiteLLM | **Fails**: 400 `ChatCompletionRequestUserMessageContent`, on LiteLLM 1.83 and 1.106. A direct `chat/completions` call to Go for GLM with a one-page PDF as a `file` part answered 200 and read it correctly (2026-10-23), so the cause of the 400 is not known. Adding `glm-5.3-flash` to `RASTERIZE_PDF_MODELS` should work, because GLM reads images, but it is not tested |

## The rasterizer

| Setting | Default | Why |
|---|---|---|
| `RASTERIZE_DPI` | 150 | These three together: a benchmark of invoices and receipts read the pages as well as the PDF |
| `RASTERIZE_MAX_WIDTH` | 1600 px | |
| `RASTERIZE_QUALITY` | 75 (JPEG) | PNG is wrong here: a 150 dpi scan is 4 to 5 MB per page |
| `RASTERIZE_PAGE_CAP` | 8 pages | Pages after the cap are dropped |
| `RASTERIZE_BYTES_BUDGET` | 5 MiB | In a 106-document sample the median document rendered to 277 KB, so 5 MiB kept 105 of 106 whole |

Rules the code follows:

- **A trim is logged, never silent.** The shim log says `DROPPED <n> page(s) over the cap`.
  A model that did not get page 9 looks like a model that could not read page 9.
- **On any failure, the shim sends the PDF unchanged** (it cannot decode it, `pdftoppm`
  fails, or no page comes out). LiteLLM and the provider then report the real error.
- **The fonts in the shim image are required.** A PDF that names a font without embedding it
  (many invoicing tools name Arial) renders with every letter missing when no substitute
  font is installed. The lines, logos and boxes still draw, so the page looks like a
  redacted scan, and `pdftoppm` exits 0. The image installs `ttf-liberation` (same metrics
  as Arial, Times New Roman, Courier New) and `ttf-dejavu`. The shim logs an error if
  poppler reports a missing font.
- **Never add an Anthropic or Gemini model to the list.** They read the PDF itself, and
  better than a picture of it.

## How to check it

- The shim log shows one line per rasterized request:
  `docker compose logs litellm-headers-shim | grep rasterized`.
- Test with a PDF whose content you know, and check a value the model cannot guess (a
  total, a date). "The model answered" is not a test: a model that never got the PDF also
  answers.
- If a model invents the content, check that the running LiteLLM is the patched image
  ([../gateway/patched/README.md](../gateway/patched/README.md), "Check the running server").
