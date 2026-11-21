"""Part 6: the paved track. A credential-injecting egress gateway for the sandbox.

This is the pattern CNCF's new agent runtimes ship as a default (Agent Substrate's
egress gateway, OpenShell's providers): the sandbox holds no credential and has
no route out except this gateway. The script sends `Authorization: placeholder`;
the gateway discards it and adds the real credential, but only for a destination
the egress policy lists. Everything else is dropped (default deny).

That closes Part 4's theft for good: there is nothing in the sandbox to steal.
It doesn't answer Part 3's question. With EGRESS_PERMITS off, the gateway spends
the credential for anyone who reaches it, so a poisoned script deletes
prod-archive *through* the gateway, with a credential it never saw.

EGRESS_PERMITS=true adds the missing checkpoints:
  * Part 3: the request must carry the permit its run_script call was made with
    (x-highway-permit). The gateway verifies it against the STS and asks OPA
    whether *that delegation* covers this method on this path.
  * Part 5: every decision is signed into the black box before the credential
    goes on. With AUDIT_REQUIRED, no record means no request.

Routes are `/<host:port>/<path>`, e.g. DELETE /mcp-tools:8000/store/v1/buckets/x.
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

from . import auditlog, config
from .log import log
from .permits import act_chain

# host -> rule. Mirrors a Substrate EgressPolicy: allowed hostnames, optional path
# prefix, and a header to replace with a credential read from a mounted Secret.
DEFAULT_POLICY = {
    "mcp-tools:8000": {"prefix": "/store/", "credential": "store-token",
                       "header": "Authorization", "value_prefix": "Bearer "},
}
POLICY = json.loads(os.environ.get("EGRESS_POLICY", "") or "null") or DEFAULT_POLICY
CRED_DIR = os.environ.get("EGRESS_CRED_DIR", "/var/run/egress")
OPA_URL = os.environ.get("OPA_URL", "http://127.0.0.1:8181/v1/data/highway/egress/decision")
# Lab shortcut: the runner forwards the permit the MCP gateway accepted. Production
# would exchange it again at the STS for audience "egress-gateway" (see README).
PERMIT_AUDIENCE = os.environ.get("PERMIT_AUDIENCE", "mcp-gateway")
# Part 7: who is asking. "mesh" = Linkerd's l5d-client-id (Part 6). "actor-jwt" = the
# Authorization header carries an actor JWT that Agent Substrate's egress gateway
# injected (actorJwt effect); verified against Substrate's IdP (ate-idp-server).
CALLER_FROM = os.environ.get("CALLER_FROM", "mesh")
ACTOR_JWKS_URL = os.environ.get("ACTOR_JWKS_URL", "")
ACTOR_AUDIENCE = os.environ.get("ACTOR_AUDIENCE", "store-gate")

_sts_keys: KeySet | None = None
_actor_keys: KeySet | None = None


def _actor(request: Request) -> str:
    """Part 7: the actor identity Substrate vouched for, or "-"."""
    global _actor_keys
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer ") or not ACTOR_JWKS_URL:
        return "-"
    try:
        if _actor_keys is None:
            _actor_keys = KeySet.import_key_set(httpx.get(ACTOR_JWKS_URL, timeout=5).json())
        claims = jwt.decode(auth[7:], _actor_keys, algorithms=["ES256", "RS256"]).claims
        jwt.JWTClaimsRegistry(aud={"essential": True, "value": ACTOR_AUDIENCE},
                              exp={"essential": True}).validate(claims)
        return str(claims.get("sub", "-"))   # actor/<atespace>/<actor-name>
    except Exception as e:  # noqa: BLE001
        _actor_keys = None
        log("egress=actor_jwt_rejected", error=f"{type(e).__name__}: {e}")
        return "-"


def _credential(name: str) -> str:
    with open(os.path.join(CRED_DIR, name)) as f:
        return f.read().strip()


def _permit(token: str) -> tuple[dict | None, str | None]:
    global _sts_keys
    if not token:
        return None, "no permit (x-highway-permit)"
    try:
        if _sts_keys is None:
            _sts_keys = KeySet.import_key_set(httpx.get(f"{config.STS_URL}/.well-known/jwks.json", timeout=5).json())
        claims = jwt.decode(token, _sts_keys, algorithms=["ES256"]).claims
        jwt.JWTClaimsRegistry(iss={"essential": True, "value": config.STS_ISSUER},
                              aud={"essential": True, "value": PERMIT_AUDIENCE},
                              exp={"essential": True}).validate(claims)
        return claims, None
    except Exception as e:  # noqa: BLE001
        _sts_keys = None
        return None, f"permit rejected: {type(e).__name__}: {e}"


def _deny(status: int, why: str, **who) -> JSONResponse:
    log("egress=DENY", **who, reason=why)
    return JSONResponse({"error": why}, status_code=status)


async def forward(request: Request) -> Response:
    host, _, rest = request.path_params["target"].partition("/")
    path = "/" + rest
    method = request.method
    caller = _actor(request) if CALLER_FROM == "actor-jwt" else request.headers.get("l5d-client-id", "-")
    where = {"method": method, "host": host, "path": path, "caller": caller}

    rule = POLICY.get(host)
    if rule is None or not path.startswith(rule.get("prefix", "/")):
        await auditlog.aemit("egress.decision", decision="DENY", reasons=["destination not in egress policy"], **where)
        return _deny(403, "destination not in egress policy (default deny)", **where)

    permit, who = None, {"sub": "-", "act": "-", "task_id": "-"}
    if config.EGRESS_PERMITS:
        permit, perr = _permit(request.headers.get("x-highway-permit", ""))
        opa_input = {"method": method, "host": host, "path": path, "caller": caller,
                     "permit": permit, "errors": [perr] if perr else []}
        async with httpx.AsyncClient(timeout=5) as c:
            decision = (await c.post(OPA_URL, json={"input": opa_input})).json().get("result") or {}
        allow, reasons = decision.get("allow", False), sorted(decision.get("deny", ["no decision"]))
        who = {"sub": (permit or {}).get("sub", "-"), "act": act_chain(permit or {}),
               "task_id": str((permit or {}).get("task_id", "-"))}
    else:
        allow, reasons = True, []

    # Part 5: record before the credential goes on. AUDIT_REQUIRED fails closed.
    recorded = await auditlog.aemit(
        "egress.decision", decision="ALLOW" if allow else "DENY", credential=rule["credential"],
        jti=(permit or {}).get("jti"), scope=(permit or {}).get("scope"),
        reasons=None if allow else reasons, **where, **who)
    if allow and not recorded and config.AUDIT_REQUIRED:
        allow, reasons = False, ["audit unavailable (AUDIT_REQUIRED): no record, no action"]
    if not allow:
        return _deny(403, "; ".join(reasons), **where, **who)

    # The credential goes on here, outside the sandbox. The placeholder is discarded.
    headers = {rule["header"]: rule.get("value_prefix", "") + _credential(rule["credential"]),
               "x-highway-sub": who["sub"], "x-highway-task": who["task_id"],
               "x-highway-jti": (permit or {}).get("jti", "-")}
    if ct := request.headers.get("content-type"):
        headers["content-type"] = ct
    log("egress=INJECT", **where, credential=rule["credential"], **who)
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            up = await c.request(method, f"http://{host}{path}", content=await request.body(), headers=headers)
    except httpx.HTTPError as e:
        log("egress=upstream_error", **where, error=type(e).__name__)
        return JSONResponse({"error": f"upstream {type(e).__name__}"}, status_code=502)
    return Response(up.content, status_code=up.status_code,
                    media_type=up.headers.get("content-type", "application/json"))


async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


app = Starlette(routes=[
    Route("/healthz", healthz),
    Route("/{target:path}", forward, methods=["GET", "POST", "PUT", "PATCH", "DELETE"]),
])


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    log("egress-gateway starting", port=port, permits=config.EGRESS_PERMITS, caller_from=CALLER_FROM,
        routes=",".join(POLICY), opa=OPA_URL if config.EGRESS_PERMITS else "-")
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


if __name__ == "__main__":
    main()
