#!/usr/bin/env python3
"""Apply the LiteLLM patches at image-build time. See README.md.

Deliberately NOT a vendored copy of the upstream files. Each edit is anchored on
a unique block of surrounding source, so a LiteLLM bump that moves that code
makes the BUILD FAIL. A vendored copy would keep building and quietly reinstate
stock behaviour for every other change in the same file.

Anchors are located in the ORIGINAL text and spliced back to front in one pass.
Applying them sequentially with str.replace does not work: neighbouring hunks
share context lines, so an earlier edit rewrites the ground a later anchor is
standing on and it then matches zero times.

Each file is patched under every install root given on the command line. The
Dockerfile passes only the venv site-packages; it says why.

Written against v1.106.2. Until v1.106 these hunks were a generated JSON blob
for v1.83.14; four of its eight fixes are upstream now (README.md, "What
upstream fixed"), so they are gone from here and the Dockerfile asserts them.
"""
import sys
from pathlib import Path

ADAPTER = "litellm/llms/anthropic/pass_through/adapters/transformation.py"
COMMON_UTILS = "litellm/litellm_core_utils/prompt_templates/common_utils.py"
OPENAI_TYPES = "litellm/types/llms/openai.py"

EDITS = [
    # 1. Top-level user `document` -> OpenAI `file` part, not image_url.
    (
        ADAPTER,
        '''\
                        elif content.get("type") == "document":
                            # Convert Anthropic document format (PDF, etc.) to OpenAI format
                            source = content.get("source", {})
                            openai_image_url = self._translate_anthropic_image_to_openai(cast(dict, source))

                            if openai_image_url:
                                image_url_obj = ChatCompletionImageUrlObject(url=openai_image_url)
                                doc_obj = ChatCompletionImageObject(type="image_url", image_url=image_url_obj)
                                self._add_cache_control_if_applicable(content, doc_obj, model)
                                new_user_content_list.append(doc_obj)
''',
        '''\
                        elif content.get("type") == "document":
                            # PATCHED: an OpenAI `file` part, not image_url (patched/README.md).
                            doc_obj = self._translate_anthropic_document_to_openai(content.get("source"))
                            if doc_obj is not None:
                                self._add_cache_control_if_applicable(content, doc_obj, model)
                                new_user_content_list.append(doc_obj)  # type: ignore[arg-type]
''',
    ),
    # 2. `document` inside a tool_result -> `file` part. Upstream sends it through
    #    the image translator, which yields image_url "data:application/pdf;...".
    (
        ADAPTER,
        '''\
            case "image" | "document":
                return self._tool_result_image_part(block.get("source"))
''',
        '''\
            case "image":
                return self._tool_result_image_part(block.get("source"))
            case "document":
                # PATCHED: an OpenAI `file` part, not image_url (patched/README.md).
                return self._translate_anthropic_document_to_openai(  # type: ignore[return-value]
                    block.get("source")
                )
''',
    ),
    # 3. The translator both branches above call.
    (
        ADAPTER,
        '''\
    def _tool_result_content(self, raw_content: object) -> ToolResultContent:
''',
        '''\
    def _translate_anthropic_document_to_openai(self, doc_source: object, filename: str = "document.pdf"):
        """PATCHED. Anthropic `document` source -> OpenAI/OpenRouter `file` content part.

        NOT an image_url. Upstream reuses _translate_anthropic_image_to_openai for
        documents, which produces `image_url: {url: "data:application/pdf;base64,..."}`.
        Providers that sniff the data URI (Google) cope; Z.AI rejects it with "Could
        not decode image", and OpenRouter's documented shape for a PDF is a `file`
        part regardless. Emitting the right shape works for both.
        """
        from litellm.types.llms.openai import ChatCompletionFileObject, ChatCompletionFileObjectFile

        if not isinstance(doc_source, dict):
            return None
        source_type = doc_source.get("type")
        if source_type == "base64":
            media_type = doc_source.get("media_type") or "application/pdf"
            data = doc_source.get("data") or ""
            if not data:
                return None
            file_data = f"data:{media_type};base64,{data}"
        elif source_type == "url":
            file_data = doc_source.get("url") or ""
            if not file_data:
                return None
        else:
            # `text` documents carry their content inline; nothing to upload.
            return None
        return ChatCompletionFileObject(
            type="file",
            file=ChatCompletionFileObjectFile(filename=filename, file_data=file_data),
        )

    def _tool_result_content(self, raw_content: object) -> ToolResultContent:
''',
    ),
    # 4. Upstream hoists image_url parts out of `tool` messages into a following
    #    user message (an OpenAI tool message may carry text only). A `file` part
    #    needs the same, or the PDF stays in the tool message.
    (
        COMMON_UTILS,
        '''\
def _is_image_url_part(part: object) -> bool:
    return isinstance(part, dict) and part.get("type") == "image_url"
''',
        '''\
def _is_image_url_part(part: object) -> bool:
    # PATCHED: `file` too, so a PDF from a tool result is hoisted like an image.
    return isinstance(part, dict) and part.get("type") in ("image_url", "file")
''',
    ),
    # 5. Annotation type widened, or an OpenRouter PDF response 500s after billing.
    (
        OPENAI_TYPES,
        '''\
class ChatCompletionAnnotation(TypedDict, total=False):
    type: Literal["url_citation"]
    """The type of the URL citation. Always `url_citation`."""
''',
        '''\
class ChatCompletionAnnotation(TypedDict, total=False):
    type: str
    """Annotation kind. PATCHED.

    WAS `Literal["url_citation"]`, which made LiteLLM reject otherwise-valid
    upstream responses. OpenRouter returns `{"type": "file", "file": {...}}`
    annotations whenever its file-parser handled a PDF, and pydantic raised
    `annotations.0.type Input should be 'url_citation'` -- surfaced to the
    client as a 500 APIConnectionError "Invalid response object" AFTER the model
    had answered correctly and the tokens had been billed. Annotations are
    passive metadata; an unrecognised kind is not a reason to discard the
    completion. Kept permissive rather than enumerating vendors.
    """
''',
    ),
]


def patch_file(path, edits):
    src = path.read_text(encoding="utf-8")
    spans = []
    for i, (old, new) in enumerate(edits, 1):
        n = src.count(old)
        if n != 1:
            sys.exit(
                f"FAIL: {path} hunk {i}/{len(edits)} matched {n} times, expected 1.\n"
                f"  Upstream moved. Reconcile the patch against the new LiteLLM\n"
                f"  before shipping -- do NOT relax this check.\n"
                f"  anchor starts: {old.splitlines()[0][:90]!r}"
            )
        start = src.index(old)
        spans.append((start, start + len(old), new, i))
    spans.sort()
    for (_, end_a, _, ia), (start_b, _, _, ib) in zip(spans, spans[1:]):
        if end_a > start_b:
            sys.exit(f"FAIL: {path} hunks {ia} and {ib} overlap; regenerate with less context")
    for start, end, new, _ in reversed(spans):
        src = src[:start] + new + src[end:]
    path.write_text(src, encoding="utf-8")
    print(f"patched {len(edits)} hunk(s) in {path}")


def main(roots):
    if not roots:
        sys.exit("usage: apply_patches.py <install-root> [<install-root> ...]")
    by_file = {}
    for rel, old, new in EDITS:
        by_file.setdefault(rel, []).append((old, new))
    for root in roots:
        for rel, edits in by_file.items():
            path = Path(root) / rel
            if not path.exists():
                sys.exit(f"FAIL: {path} does not exist")
            patch_file(path, edits)


if __name__ == "__main__":
    main(sys.argv[1:])
