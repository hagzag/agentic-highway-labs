"""Chat-completions client for any OpenAI-compatible endpoint (LiteLLM by default).

Part 1 note: LLM_API_KEY is a static, borrowed credential mounted from a Secret.
That is deliberate. Part 3 moves it behind a gateway (LLM_AUTH=svid): the agent
sends a JWT-SVID to the llm-gateway, which holds the key and runs the mock.
"""
import httpx

from . import config
from .mock_llm import mock_chat


def chat(role: str, messages: list[dict], tools: list[dict] | None = None) -> dict:
    """Return one assistant message: {"content": str|None, "tool_calls": [...]|None}."""
    if config.LLM_MODE == "mock" and config.LLM_AUTH != "svid":
        return mock_chat(role, messages, tools)

    body = {"model": config.LLM_MODEL, "messages": messages, "temperature": 0}
    if tools:
        body["tools"] = tools
    resp = httpx.post(
        f"{config.LLM_BASE_URL.rstrip('/')}/v1/chat/completions",
        headers={"Authorization": f"Bearer {_credential()}"},
        json=body,
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]


def _credential() -> str:
    if config.LLM_AUTH == "svid":
        from . import svid
        return svid.token("llm-gateway")  # who I am, for this audience only; expires on its own
    return config.LLM_API_KEY             # Parts 1-2: the borrowed static key
