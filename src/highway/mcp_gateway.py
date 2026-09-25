"""Part 3: the MCP gateway. Policy enforcement point in front of mcp-tools.

Every request must carry two tokens:
    Authorization: Bearer <permit>    what the human delegated (from the STS)
    Actor-Token:   <JWT-SVID>          who is presenting it right now (from SPIRE)

This file only does the cryptography (PEP). The decision is OPA's (PDP):
the verified claims, the caller and the JSON-RPC call go to OPA as `input`,
and OPA answers allow/deny with reasons. See practice/part3/policy/.
"""
import json
import os

import httpx
import uvicorn
from joserfc import jwt
from joserfc.jwk import KeySet
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import config, svid
from .log import log
from .permits import act_chain

UPSTREAM = os.environ.get("UPSTREAM_MCP_URL", "http://mcp-tools:8000/mcp")
OPA_URL = os.environ.get("OPA_URL", "http://127.0.0.1:8181/v1/data/highway/mcp/decision")
AUDIENCE = "mcp-gateway"
HOP = {"host", "content-length", "connection", "authorization", "actor-token", "transfer-encoding"}

_sts_keys: KeySet | None = None


def _permit(request: Request) -> tuple[dict | None, str | None]:
    global _sts_keys
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return None, "no permit (Authorization: Bearer)"
    try:
        if _sts_keys is None:
            _sts_keys = KeySet.import_key_set(httpx.get(f"{config.STS_URL}/.well-known/jwks.json", timeout=5).json())
        claims = jwt.decode(auth[7:], _sts_keys, algorithms=["ES256"]).claims
        jwt.JWTClaimsRegistry(iss={"essential": True, "value": config.STS_ISSUER},
                              aud={"essential": True, "value": AUDIENCE},
                              exp={"essential": True}).validate(claims)
        return claims, None
    except Exception as e:  # noqa: BLE001
        _sts_keys = None  # STS restarted with a new key? refetch next time
        return None, f"permit rejected: {type(e).__name__}: {e}"


def _caller(request: Request) -> tuple[str | None, str | None]:
    tok = request.headers.get("actor-token")
    if not tok:
        return None, "no actor token (JWT-SVID)"
    try:
        return svid.validate(tok, AUDIENCE), None
    except Exception as e:  # noqa: BLE001
        return None, f"actor token rejected: {type(e).__name__}"


async def mcp(request: Request) -> Response:
    body = await request.body()
    try:
        rpc = json.loads(body) if body else {}
    except ValueError:
        rpc = {}
    rpc = rpc if isinstance(rpc, dict) else {}
    method = rpc.get("method", request.method)
    params = rpc.get("params") or {}
    tool = params.get("name") if method == "tools/call" else None
    args = (params.get("arguments") or {}) if method == "tools/call" else {}

    permit, perr = _permit(request)
    caller, cerr = _caller(request)
    opa_input = {"method": method, "tool": tool, "args": args, "permit": permit, "caller": caller,
                 "errors": [e for e in (perr, cerr) if e]}
    async with httpx.AsyncClient(timeout=5) as c:
        decision = (await c.post(OPA_URL, json={"input": opa_input})).json().get("result") or {}
    allow, reasons = decision.get("allow", False), sorted(decision.get("deny", ["no decision"]))

    who = {"sub": (permit or {}).get("sub", "-"), "act": act_chain(permit or {}),
           "caller": svid.short(caller), "task_id": (permit or {}).get("task_id", "-")}
    if not allow:
        log("gateway=DENY", method=method, tool=tool or "-", **who, reason="; ".join(reasons))
        if method == "tools/call":  # a tool error the model can read, not a crashed session
            return JSONResponse({"jsonrpc": "2.0", "id": rpc.get("id"), "result": {
                "resultType": "complete",  # required by the 2026-07-28 MCP schema
                "content": [{"type": "text", "text": "DENIED by policy: " + "; ".join(reasons)}], "isError": True}})
        return JSONResponse({"jsonrpc": "2.0", "id": rpc.get("id"),
                             "error": {"code": -32001, "message": "; ".join(reasons)}}, status_code=403)
    if method == "tools/call":
        log("gateway=ALLOW", tool=tool, **who, args=json.dumps(args))

    # l5d-*: the mesh's view of *this* hop. Never forward it; the next proxy sets its own.
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP and not k.lower().startswith("l5d-")}
    headers["x-highway-sub"] = who["sub"]          # downstream sees on whose behalf
    headers["x-highway-act"] = who["act"]
    async with httpx.AsyncClient(timeout=30) as c:
        up = await c.request(request.method, UPSTREAM, content=body, headers=headers)
    out = {k: v for k, v in up.headers.items() if k.lower() not in HOP | {"content-encoding"}}
    return Response(up.content, status_code=up.status_code, headers=out)


async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


app = Starlette(routes=[Route("/mcp", mcp, methods=["GET", "POST", "DELETE"]), Route("/healthz", healthz)])


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    log("mcp-gateway starting", port=port, upstream=UPSTREAM, opa=OPA_URL)
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


if __name__ == "__main__":
    main()
