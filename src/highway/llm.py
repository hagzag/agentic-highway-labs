"""Chat-completions client for any OpenAI-compatible endpoint (LiteLLM by default).

Part 1 note: LLM_API_KEY is a static, borrowed credential mounted from a Secret.
That is deliberate. Part 3 moves it behind a gateway.
"""
import httpx

from . import config
from .mock_llm import mock_chat


def chat(role: str, messages: list[dict], tools: list[dict] | None = None) -> dict:
    """Return one assistant message: {"content": str|None, "tool_calls": [...]|None}."""
    if config.LLM_MODE == "mock":
        return mock_chat(role, messages, tools)

    body = {"model": config.LLM_MODEL, "messages": messages, "temperature": 0}
    if tools:
        body["tools"] = tools
    resp = httpx.post(
        f"{config.LLM_BASE_URL.rstrip('/')}/v1/chat/completions",
        headers={"Authorization": f"Bearer {config.LLM_API_KEY}"},
        json=body,
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]
