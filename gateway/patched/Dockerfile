# LiteLLM with upstream defects patched. Read ./README.md before any bump.
#
# The edits are applied by apply_patches.py, which anchors each hunk on a unique
# block of upstream source and EXITS NON-ZERO if that anchor stops matching. A
# LiteLLM bump that moves the surrounding code therefore fails the build, which
# is the point -- vendoring the two 70 KB files instead would keep building and
# quietly reinstate stock behaviour for every other change in them.
#
# Only the venv copy is patched. Up to v1.83 the image shipped litellm twice
# (/app/litellm and the venv) and both had to be patched, because a hand-check
# from cwd /app imported the /app copy while the proxy imported the venv one.
# From v1.106 /app/litellm holds only proxy/, and `import litellm` from /app
# resolves to the venv (checked 2026-10-23). After a bump, run
# `python -c "import litellm; print(litellm.__file__)"` from /app. If it does not
# print the venv path, the second copy is back: patch it too.
FROM ghcr.io/berriai/litellm:v1.106.2@sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7

ARG VENV=/app/.venv/lib/python3.13/site-packages
COPY apply_patches.py /tmp/apply_patches.py

USER root
RUN python /tmp/apply_patches.py "${VENV}" \
 && find "${VENV}/litellm" -name '__pycache__' -type d -exec rm -rf {} + \
 && rm -f /tmp/apply_patches.py

# Refuse to ship a silently-unpatched image: check the code the SERVER imports.
# The second block asserts fixes we USED to patch and now take from upstream, so
# a bump that loses one of them fails here instead of in production.
RUN python -c "\
import inspect;\
import litellm.llms.anthropic.pass_through.adapters.transformation as t;\
cls = t.LiteLLMAnthropicMessagesAdapter;\
assert hasattr(cls, '_translate_anthropic_document_to_openai'), 'document translator missing';\
assert '_translate_anthropic_document_to_openai' in inspect.getsource(cls._tool_result_part), 'tool_result document patch missing';\
assert '_translate_anthropic_document_to_openai' in inspect.getsource(cls.translate_anthropic_messages_to_openai), 'top-level document patch missing';\
from litellm.litellm_core_utils.prompt_templates import common_utils as cu;\
assert cu._is_image_url_part({'type': 'file'}), 'file hoist patch missing';\
from litellm.types.llms.openai import ChatCompletionAnnotation as A;\
assert A.__annotations__['type'] is str, 'annotation patch missing';\
print('patched image verified')"
RUN python -c "\
import inspect;\
import litellm.llms.anthropic.pass_through.adapters.transformation as t;\
assert 'reasoning_content' in inspect.getsource(t.LiteLLMAnthropicMessagesAdapter.translate_anthropic_messages_to_openai), 'upstream reasoning_content fix gone';\
from litellm.llms.anthropic.pass_through.messages.transformation import AnthropicMessagesConfig as M;\
assert M().should_strip_billing_metadata() is False, 'upstream now strips the billing header on first-party Anthropic';\
assert '_normalize_system_role_messages' not in inspect.getsource(M.transform_anthropic_messages_request), 'first-party path now normalizes system (strips billing header)';\
from litellm.llms.openai.chat.gpt_transformation import OpenAIGPTConfig as O;\
src = inspect.getsource(O._transform_messages);\
assert 'drop_tool_reference_parts_from_tool_messages' in src and 'hoist_images_from_tool_messages' in src, 'upstream tool_reference drop / media hoist gone';\
print('upstream fixes verified')"
