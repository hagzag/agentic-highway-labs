"""Part 3: the LLM egress gateway. The only pod that holds LLM_API_KEY.

Parts 1-2 mounted a static, borrowed key into every agent. Here the agents hold
nothing: they present a JWT-SVID (audience "llm-gateway") and the gateway
decides whether to spend the key on their behalf. One place to rotate, rate
limit, log and cut off.

LLM_MODE=mock still works offline: the gateway answers with the deterministic
mock, choosing planner/executor behaviour from the caller's SPIFFE ID.
"""
import os

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from . import config, svid
from .log import log
from .mock_llm import mock_chat

TD = "spiffe://highway.lab/ns/migration/sa"
ROLES = {f"{TD}/planner-agent": "planner", f"{TD}/executor-agent": "executor"}


async def chat(request: Request) -> JSONResponse:
    auth = request.headers.get("authorization", "")
    try:
        caller = svid.validate(auth.removeprefix("Bearer ").strip(), "llm-gateway")
    except Exception as e:  # noqa: BLE001
        reason = "no JWT-SVID" if not auth.startswith("Bearer ") else f"bad JWT-SVID: {type(e).__name__}"
        log("llm=DENY", reason=reason)
        return JSONResponse({"error": {"message": reason}}, status_code=401)
    role = ROLES.get(caller)
    if role is None:
        log("llm=DENY", caller=svid.short(caller), reason="not an allowed caller")
        return JSONResponse({"error": {"message": "caller not allowed"}}, status_code=403)

    body = await request.json()
    log("llm=ALLOW", caller=svid.short(caller), model=body.get("model", config.LLM_MODEL), mode=config.LLM_MODE)
    if config.LLM_MODE == "mock":
        msg = mock_chat(role, body["messages"], body.get("tools"))
        return JSONResponse({"choices": [{"index": 0, "message": {"role": "assistant", **msg}}]})

    async with httpx.AsyncClient(timeout=60) as c:
        up = await c.post(f"{config.LLM_BASE_URL.rstrip('/')}/v1/chat/completions", json=body,
                          headers={"Authorization": f"Bearer {config.LLM_API_KEY}"})
    return JSONResponse(up.json(), status_code=up.status_code)


async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


app = Starlette(routes=[Route("/v1/chat/completions", chat, methods=["POST"]), Route("/healthz", healthz)])


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    log("llm-gateway starting", port=port, mode=config.LLM_MODE, upstream=config.LLM_BASE_URL,
        key=f"{len(config.LLM_API_KEY)} chars")
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


if __name__ == "__main__":
    main()
