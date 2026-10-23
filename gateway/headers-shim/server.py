#!/usr/bin/env python3
"""
LiteLLM headers shim -- re-injects upstream Anthropic ratelimit response headers
that LiteLLM v1.83.x strips during /v1/messages translation.

Why: Claude Code reads `anthropic-ratelimit-unified-5h-utilization` and
`anthropic-ratelimit-unified-7d-utilization` (plus ~11 other ratelimit headers)
from the response to populate the 5h/7d statusline indicators. Direct-to-
api.anthropic.com returns them; LiteLLM strips them. Empirical 2026-05-09.

How: this shim sits between Caddy and LiteLLM. It transparently proxies all
requests. A background task fires a tiny `claude-haiku-4-5` call with
`max_tokens=1` to api.anthropic.com every REFRESH_INTERVAL seconds using the
last-seen OAuth bearer, captures the ratelimit headers, and caches them.
On each Claude /v1/messages response back to the client, the cached headers
are merged into the proxy response so Claude Code can populate the statusline.

Cost: 1 extra haiku call per REFRESH_INTERVAL (default 45s) regardless of
user activity, which is ~13 input tokens + 1 output token per refresh --
negligible against Max budget. The user's actual /v1/messages calls are
NOT doubled -- they go through this shim once, hit LiteLLM once.

SECOND JOB -- PDF rasterization for models that refuse a file part.
OpenCode Go answers 400 `.messages[0]: file must have a file_id or file_data`
to every OpenAI `file` content part, with `file_data` present and correct on
the wire, and it serves no /files endpoint (404), so `file_id` is not an
option either. It does accept `image_url`. So for the models named in
RASTERIZE_PDF_MODELS, this shim turns each Anthropic `document` block into
per-page JPEG `image` blocks BEFORE LiteLLM sees the body, and the existing
image path carries it the rest of the way.

It lives here and not in another litellm patch hunk for three reasons: this
is our own code with no upstream anchor to break, the shim already parses
this exact body, and the patched adapter already promotes media out of a
tool_result, which is the shape a Claude Code `Read` of a PDF produces.

The list is EMPTY by default on purpose. Anthropic and Gemini read a PDF
natively and better than they read a picture of one; rasterizing for them
would be a downgrade. See ../CLAUDE.md, the OpenCode Go traps.

THIRD JOB -- drop `\\0` regex patterns from tool schemas.
OpenCode Go answers 400 with only `{'model': 'deepseek-v4.1-flash'}` when any
tool schema has a `pattern` with a `\\0` in it. Claude Code 2.1.282 sends one
on every interactive turn: the built-in `Artifact` tool has
`file_paths.items.pattern: "^[^\\0]*$"`. `-p` mode does not send that tool,
so a `-p` test passes and every interactive turn fails. For the models named
in STRIP_NUL_PATTERN_MODELS, this shim removes those `pattern` keys and keeps
the tool. The pattern only rejects a NUL byte in a path, so the model loses
nothing it needs. Empty by default, like the list above.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import glob
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import time
from typing import Any, Optional

from aiohttp import ClientSession, ClientTimeout, web

LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm:4000")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "4001"))
REFRESH_MODEL = os.environ.get("REFRESH_MODEL", "claude-haiku-4-5")
REFRESH_INTERVAL = int(os.environ.get("REFRESH_INTERVAL", "45"))
# aiohttp's web.Application() defaults to a 1 MiB request-body cap and 413s
# anything larger ("Maximum request body size 1048576 exceeded"). That is far
# too small for this proxy: a single scanned PDF classified through
# /v1/messages is ~1.1 MB once base64-encoded, so document classification hit
# the ceiling silently from the client's point of view. 32 MiB matches Claude
# Code's own client-side attachment limit, so the shim stops being the first
# thing to say no.
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(32 * 1024 * 1024)))
ANTHROPIC_URL = "https://api.anthropic.com"

# -- PDF rasterization (see the second job in the module docstring) ----------
# Comma-separated gateway model_name values. Empty means the shim never
# touches a body, which is the default and the correct behaviour for every
# provider that reads a PDF natively.
RASTERIZE_PDF_MODELS = {
    m.strip() for m in os.environ.get("RASTERIZE_PDF_MODELS", "").split(",") if m.strip()
}
# -- NUL-pattern strip (see the third job in the module docstring) -----------
STRIP_NUL_PATTERN_MODELS = {
    m.strip() for m in os.environ.get("STRIP_NUL_PATTERN_MODELS", "").split(",") if m.strip()
}
# The regex spellings of NUL, plus a literal NUL character.
_NUL_PATTERN = re.compile(r"\\0|\\x00|\\u0000|\x00")
# dpi, width and quality are the values a benchmark harness
# measured on a corpus of invoices and receipts: JPEG 75 at 150 dpi scaled to 1600 px reads
# identically to the PDF on those documents. PNG is wrong here -- a 150 dpi scan
# lands at 4-5 MB per page.
RASTERIZE_DPI = int(os.environ.get("RASTERIZE_DPI", "150"))
RASTERIZE_MAX_WIDTH = int(os.environ.get("RASTERIZE_MAX_WIDTH", "1600"))
RASTERIZE_QUALITY = int(os.environ.get("RASTERIZE_QUALITY", "75"))
# Budget, measured against a 106-document sample: the median
# document renders to 277 KB and the 90th percentile to 722 KB, so 5 MiB keeps
# 105 of 106 whole. The one exception is a 15-page document, which the page cap
# trims. A trim is LOGGED, never silent: a bank statement cut at page 3 scores
# as a model that could not read page 3, which is a different finding.
RASTERIZE_PAGE_CAP = int(os.environ.get("RASTERIZE_PAGE_CAP", "8"))
RASTERIZE_BYTES_BUDGET = int(os.environ.get("RASTERIZE_BYTES_BUDGET", str(5 * 1024 * 1024)))

# State (single-process, single-user assumed):
_cache: dict[int, tuple[float, dict[str, str]]] = {}
_latest_bearer: Optional[str] = None

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shim")

HOP_BY_HOP = {"host", "content-length", "transfer-encoding", "content-encoding", "connection"}


async def fetch_ratelimits(bearer: str) -> dict[str, str]:
    """Tiny POST to api.anthropic.com just to read upstream ratelimit response headers."""
    timeout = ClientTimeout(total=15)
    async with ClientSession(timeout=timeout) as s:
        async with s.post(
            f"{ANTHROPIC_URL}/v1/messages",
            headers={
                "Authorization": bearer,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            },
            json={
                "model": REFRESH_MODEL,
                "max_tokens": 1,
                "messages": [{"role": "user", "content": "_"}],
            },
        ) as r:
            return {
                k: v for k, v in r.headers.items()
                if k.lower().startswith("anthropic-")
            }


async def background_refresh() -> None:
    """Refresh cache every REFRESH_INTERVAL seconds using the most recent OAuth bearer."""
    while True:
        try:
            await asyncio.sleep(REFRESH_INTERVAL)
            if _latest_bearer is None:
                continue
            key = hash(_latest_bearer)
            try:
                rl = await fetch_ratelimits(_latest_bearer)
            except Exception as e:
                log.warning("refresh failed: %s", e)
                continue
            if rl:
                _cache[key] = (time.time(), rl)
                log.info("refreshed %d ratelimit headers", len(rl))
        except asyncio.CancelledError:
            return
        except Exception as e:
            log.warning("background_refresh loop error: %s", e)


def _rasterize_pdf(pdf_bytes: bytes) -> tuple[list[str], int, int]:
    """PDF bytes -> (base64 JPEG pages, pages_kept, pages_total).

    Shells out to pdftoppm (poppler-utils) with the same flags as the benchmark
    harness, so a page produced here and a page produced there are the same
    picture. Runs in a worker thread -- do not call it on the event loop.
    """
    tmp = tempfile.mkdtemp(prefix="shim-pdf-")
    try:
        src = os.path.join(tmp, "in.pdf")
        with open(src, "wb") as fh:
            fh.write(pdf_bytes)
        proc = subprocess.run(
            ["pdftoppm", "-jpeg", "-jpegopt", f"quality={RASTERIZE_QUALITY}",
             "-r", str(RASTERIZE_DPI),
             "-scale-to-x", str(RASTERIZE_MAX_WIDTH), "-scale-to-y", "-1",
             src, os.path.join(tmp, "page")],
            check=True, capture_output=True, timeout=180,
        )
        # A missing font is the one failure that produces a PLAUSIBLE page
        # rather than an error: poppler draws the rules, logos and shaded boxes
        # and silently omits every glyph, then exits 0. The model then reports a
        # redacted document, which reads like a bad scan rather than a broken
        # gateway. The image build installs ttf-liberation for exactly this, so
        # if the message ever appears again something has removed it.
        err = (proc.stderr or b"").decode("utf-8", "replace")
        if "Couldn't find a font" in err:
            log.error(
                "pdftoppm HAS NO FONT and dropped the text of this page -- the "
                "model is being sent a blank form. Check ttf-liberation in the "
                "image. poppler said: %s",
                err.strip().splitlines()[0] if err.strip() else "",
            )
        pages = sorted(glob.glob(os.path.join(tmp, "page-*.jpg")))
        kept: list[str] = []
        used = 0
        for path in pages[:RASTERIZE_PAGE_CAP]:
            size = os.path.getsize(path)
            if kept and used + size > RASTERIZE_BYTES_BUDGET:
                break
            with open(path, "rb") as fh:
                kept.append(base64.b64encode(fh.read()).decode("ascii"))
            used += size
        return kept, len(kept), len(pages)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _image_block(b64: str, cache_control: Any = None) -> dict:
    block: dict[str, Any] = {
        "type": "image",
        "source": {"type": "base64", "media_type": "image/jpeg", "data": b64},
    }
    if cache_control is not None:
        block["cache_control"] = cache_control
    return block


def _expand_content_list(items: list, stats: dict) -> list:
    """Replace every base64 PDF `document` block with its page images."""
    out = []
    for item in items:
        if not isinstance(item, dict):
            out.append(item)
            continue
        if item.get("type") == "tool_result" and isinstance(item.get("content"), list):
            item = dict(item)
            item["content"] = _expand_content_list(item["content"], stats)
            out.append(item)
            continue
        source = item.get("source")
        if (item.get("type") != "document" or not isinstance(source, dict)
                or source.get("type") != "base64"
                or source.get("media_type", "application/pdf") != "application/pdf"):
            out.append(item)
            continue
        try:
            pdf_bytes = base64.b64decode(source.get("data", ""), validate=True)
        except (binascii.Error, ValueError):
            # Not decodable here means it is not ours to rewrite. Pass it on
            # and let LiteLLM and the provider report what is wrong with it.
            out.append(item)
            continue
        try:
            pages, kept, total = _rasterize_pdf(pdf_bytes)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
            log.warning("rasterize failed, forwarding the document unchanged: %s", e)
            out.append(item)
            continue
        if not pages:
            log.warning("rasterize produced no page, forwarding the document unchanged")
            out.append(item)
            continue
        stats["docs"] += 1
        stats["pages"] += kept
        stats["dropped"] += total - kept
        cc = item.get("cache_control")
        for i, page in enumerate(pages):
            out.append(_image_block(page, cc if i == len(pages) - 1 else None))
    return out


def rasterize_documents(doc: dict) -> tuple[dict, dict]:
    """Rewrite every PDF document block in an Anthropic /v1/messages body."""
    stats = {"docs": 0, "pages": 0, "dropped": 0}
    messages = doc.get("messages")
    if not isinstance(messages, list):
        return doc, stats
    new_messages = []
    for message in messages:
        if isinstance(message, dict) and isinstance(message.get("content"), list):
            message = dict(message)
            message["content"] = _expand_content_list(message["content"], stats)
        new_messages.append(message)
    if stats["docs"]:
        doc = dict(doc)
        doc["messages"] = new_messages
    return doc, stats


def _strip_nul_patterns(node: Any) -> int:
    """Remove every `pattern` string with a NUL in it, in place. Returns the count."""
    removed = 0
    if isinstance(node, dict):
        pattern = node.get("pattern")
        if isinstance(pattern, str) and _NUL_PATTERN.search(pattern):
            del node["pattern"]
            removed += 1
        for value in node.values():
            removed += _strip_nul_patterns(value)
    elif isinstance(node, list):
        for value in node:
            removed += _strip_nul_patterns(value)
    return removed


def strip_tool_nul_patterns(doc: dict) -> list[str]:
    """Strip NUL patterns from each tool's input_schema. Returns the changed tool names."""
    changed = []
    for tool in doc.get("tools") or []:
        if isinstance(tool, dict) and _strip_nul_patterns(tool.get("input_schema")):
            changed.append(str(tool.get("name")))
    return changed


async def proxy(request: web.Request) -> web.StreamResponse:
    global _latest_bearer

    body = await request.read()

    # Track latest OAuth bearer for the background refresh task
    auth = request.headers.get("Authorization", "")

    if ((RASTERIZE_PDF_MODELS or STRIP_NUL_PATTERN_MODELS) and request.method == "POST"
            and request.path == "/v1/messages" and body):
        try:
            doc = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            doc = None
        if isinstance(doc, dict) and doc.get("model") in STRIP_NUL_PATTERN_MODELS:
            changed = strip_tool_nul_patterns(doc)
            if changed:
                body = json.dumps(doc).encode("utf-8")
                log.info("stripped NUL regex pattern(s) from tool(s) %s for %s",
                         ",".join(changed), doc.get("model"))
        if isinstance(doc, dict) and doc.get("model") in RASTERIZE_PDF_MODELS:
            t0 = time.monotonic()
            doc, stats = await asyncio.to_thread(rasterize_documents, doc)
            if stats["docs"]:
                body = json.dumps(doc).encode("utf-8")
                log.info(
                    "rasterized %d document(s) to %d page image(s) for %s in %.1fs, "
                    "body now %.1f MiB%s",
                    stats["docs"], stats["pages"], doc.get("model"),
                    time.monotonic() - t0, len(body) / 1024 / 1024,
                    f" -- DROPPED {stats['dropped']} page(s) over the cap"
                    if stats["dropped"] else "",
                )
    if auth.startswith("Bearer sk-ant-oat"):
        _latest_bearer = auth

    fwd_headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}
    target = f"{LITELLM_URL}{request.path_qs}"

    session = ClientSession(timeout=ClientTimeout(total=600))
    try:
        upstream = await session.request(
            method=request.method,
            url=target,
            headers=fwd_headers,
            data=body if body else None,
            allow_redirects=False,
        )
    except Exception as e:
        await session.close()
        log.error("upstream connect failed: %s", e)
        return web.Response(status=502, text=f"upstream connect failed: {e}")

    # Build response headers
    response_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP}

    # Inject cached anthropic-ratelimit headers for Claude /v1/messages POSTs
    if request.method == "POST" and request.path == "/v1/messages" and body:
        try:
            doc = json.loads(body)
            model = doc.get("model", "")
            if model.startswith("claude") and auth.startswith("Bearer sk-ant-oat"):
                cached = _cache.get(hash(auth))
                if cached:
                    ts, rl = cached
                    if time.time() - ts < REFRESH_INTERVAL * 4:
                        for k, v in rl.items():
                            response_headers.setdefault(k, v)
        except (json.JSONDecodeError, AttributeError, TypeError):
            pass

    response = web.StreamResponse(status=upstream.status, headers=response_headers)
    await response.prepare(request)

    try:
        async for chunk in upstream.content.iter_any():
            if chunk:
                await response.write(chunk)
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        upstream.release()
        await session.close()

    return response


async def health(request: web.Request) -> web.Response:
    return web.Response(text="ok\n")


async def _on_startup(app: web.Application) -> None:
    app["refresh_task"] = asyncio.create_task(background_refresh())


async def _on_cleanup(app: web.Application) -> None:
    task = app.get("refresh_task")
    if task:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


def main() -> None:
    app = web.Application(client_max_size=MAX_BODY_BYTES)
    app.router.add_get("/_shim_health", health)
    app.router.add_route("*", "/{path:.*}", proxy)
    app.on_startup.append(_on_startup)
    app.on_cleanup.append(_on_cleanup)
    log.info(
        "litellm-headers-shim listening on :%d, target=%s, refresh_interval=%ds, "
        "refresh_model=%s, max_body=%.1f MiB, rasterize_pdf_models=%s, "
        "strip_nul_pattern_models=%s",
        LISTEN_PORT, LITELLM_URL, REFRESH_INTERVAL, REFRESH_MODEL,
        MAX_BODY_BYTES / 1024 / 1024,
        ",".join(sorted(RASTERIZE_PDF_MODELS)) or "(none)",
        ",".join(sorted(STRIP_NUL_PATTERN_MODELS)) or "(none)",
    )
    web.run_app(app, host="0.0.0.0", port=LISTEN_PORT, access_log=None, print=None)


if __name__ == "__main__":
    main()
