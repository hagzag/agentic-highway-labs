"""Part 3: the permit office. A minimal RFC 8693 Security Token Service.

    POST /token   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
                  subject_token  = a Keycloak access token (a human) or a permit this STS issued
                  actor_token    = the calling agent's JWT-SVID (audience "sts")
                  scope, audience, task_id (optional)

It only does *delegation*, never impersonation: no actor_token, no permit. The
permit it mints says three things a signature alone could not:

    sub   who the work is for        (the human who logged in)
    act   who is doing it, nested    (executor-agent via planner-agent)
    scope what they may do           (requested ∩ what the human holds ∩ what the actor may carry)

...and it expires in PERMIT_TTL seconds. Keycloak 26.7 has an experimental
version of this (token-exchange-delegation); this file shows the moving parts.
"""
import json
import os
import time
import uuid

import httpx
import uvicorn
from joserfc import jwt
from joserfc.jwk import ECKey, KeySet
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from . import config, svid
from .log import log
from .permits import GRANT, act_chain

ISSUER = config.STS_ISSUER
KEYCLOAK_ISSUER = config.KEYCLOAK_ISSUER
KEYCLOAK_CLIENT = os.environ.get("KEYCLOAK_CLIENT", "highway-cli")
TTL = int(os.environ.get("PERMIT_TTL", "120"))
AUDIENCES = {"mcp-gateway"}

TD = "spiffe://highway.lab/ns/migration/sa"
# What a human's realm roles are worth in scopes.
ROLE_SCOPES = {
    "migrator": {"buckets:read", "buckets:copy"},
    "storage-admin": {"buckets:read", "buckets:copy", "buckets:delete"},
}
# may_act, decided by the authorization server instead of by the token:
# which agent may act for whom, and the most it may ever carry.
ACTORS = {
    f"{TD}/planner-agent": {"for": "human", "max": {"buckets:read", "buckets:copy", "buckets:delete"}},
    f"{TD}/executor-agent": {"for": f"{TD}/planner-agent", "max": {"buckets:read", "buckets:copy", "buckets:delete"}},
}
ACTORS = json.loads(os.environ["STS_ACTORS"]) if os.environ.get("STS_ACTORS") else ACTORS

KEY = ECKey.generate_key("P-256", auto_kid=True)  # restart = new key; permits live 120s anyway
_idp_keys: KeySet | None = None


class Deny(Exception):
    def __init__(self, error: str, description: str):
        super().__init__(description)
        self.error, self.description = error, description


def _idp_keyset(refresh: bool = False) -> KeySet:
    global _idp_keys
    if _idp_keys is None or refresh:
        jwks = httpx.get(f"{KEYCLOAK_ISSUER}/protocol/openid-connect/certs", timeout=10).json()
        _idp_keys = KeySet.import_key_set({"keys": [k for k in jwks["keys"] if k.get("use", "sig") == "sig"]})
    return _idp_keys


def _verify(tok: str, keys: KeySet, iss: str) -> dict:
    try:
        claims = jwt.decode(tok, keys, algorithms=["RS256", "ES256"]).claims
        jwt.JWTClaimsRegistry(iss={"essential": True, "value": iss}, exp={"essential": True}).validate(claims)
        return claims
    except Exception as e:  # noqa: BLE001
        raise Deny("invalid_grant", f"subject_token: {type(e).__name__}: {e}") from e


def _subject(tok: str) -> tuple[dict, str, set[str], dict | None]:
    """Return (claims, human, scopes the subject holds, upstream act chain)."""
    iss = _peek_iss(tok)
    if iss == KEYCLOAK_ISSUER:
        try:
            claims = _verify(tok, _idp_keyset(), iss)
        except Deny:
            claims = _verify(tok, _idp_keyset(refresh=True), iss)  # key rotated?
        if claims.get("azp") != KEYCLOAK_CLIENT:
            raise Deny("invalid_grant", f"subject_token was issued to {claims.get('azp')}, not {KEYCLOAK_CLIENT}")
        roles = claims.get("realm_access", {}).get("roles", [])
        held = set().union(*(ROLE_SCOPES.get(r, set()) for r in roles))
        return claims, claims.get("preferred_username", claims["sub"]), held, None
    if iss == ISSUER:  # a permit we issued: the next hop in the chain
        claims = _verify(tok, KeySet([KEY]), iss)
        return claims, claims["sub"], set(claims.get("scope", "").split()), claims.get("act")
    raise Deny("invalid_grant", f"subject_token issuer {iss!r} is not trusted")


def _peek_iss(tok: str) -> str:
    from .permits import claims
    try:
        return claims(tok).get("iss", "")
    except Exception as e:  # noqa: BLE001
        raise Deny("invalid_request", "subject_token is not a JWT") from e


async def token(request: Request) -> JSONResponse:
    form = await request.form()
    try:
        if form.get("grant_type") != GRANT:
            raise Deny("unsupported_grant_type", "token-exchange only")

        # 1. Who is asking: the actor proves itself with a JWT-SVID, not a client secret.
        actor_tok = form.get("actor_token")
        if not actor_tok:
            raise Deny("invalid_request", "actor_token required: this STS delegates, it never impersonates")
        try:
            actor = svid.validate(str(actor_tok), "sts")
        except Exception as e:  # noqa: BLE001
            raise Deny("invalid_client", f"actor_token is not a valid JWT-SVID for 'sts': {e}") from e
        policy = ACTORS.get(actor)
        if policy is None:
            raise Deny("unauthorized_client", f"{actor} may not act for anyone")

        # 2. For whom: the human (Keycloak) or an upstream permit.
        subj, human, held, upstream = _subject(str(form.get("subject_token", "")))

        # 3. May this actor act for this subject? (the AS-side may_act check)
        current = upstream["sub"] if upstream else "human"
        if policy["for"] != current:
            raise Deny("access_denied", f"{svid.short(actor)} may not act for {svid.short(current)}")

        # 4. Scope: never wider than what the subject holds or the actor may carry.
        requested = set(str(form.get("scope") or " ".join(held)).split())
        granted = requested & held & set(policy["max"])
        dropped = requested - granted
        if not granted:
            raise Deny("invalid_scope", f"nothing left of {sorted(requested)} for {human}")

        aud = str(form.get("audience") or "mcp-gateway")
        if aud not in AUDIENCES:
            raise Deny("invalid_target", f"unknown audience {aud}")

        task_id = str(form.get("task_id") or subj.get("task_id") or "")
        if subj.get("task_id") and task_id != subj["task_id"]:
            raise Deny("invalid_request", f"permit is for task {subj['task_id']}, not {task_id}")

        now = int(time.time())
        act = {"sub": actor, **({"act": upstream} if upstream else {})}
        claims = {
            "iss": ISSUER, "sub": human, "aud": aud, "iat": now,
            "exp": min(now + TTL, int(subj["exp"])),  # a hop can shorten a permit, never extend it
            "jti": str(uuid.uuid4()), "scope": " ".join(sorted(granted)), "act": act,
            **({"task_id": task_id} if task_id else {}),
        }
        permit = jwt.encode({"alg": "ES256", "kid": KEY.kid, "typ": "at+jwt"}, claims, KEY)
        log("sts=issued", sub=human, act=act_chain(claims), scope=claims["scope"],
            dropped=" ".join(sorted(dropped)) or "-", ttl=claims["exp"] - now, task_id=task_id or "-")
        return JSONResponse({
            "access_token": permit, "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "token_type": "Bearer", "expires_in": claims["exp"] - now, "scope": claims["scope"],
        })
    except Deny as d:
        log("sts=DENY", error=d.error, reason=d.description)
        return JSONResponse({"error": d.error, "error_description": d.description}, status_code=400)


async def jwks(_: Request) -> JSONResponse:
    return JSONResponse({"keys": [KEY.as_dict(private=False) | {"use": "sig", "alg": "ES256"}]})


async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


app = Starlette(routes=[
    Route("/token", token, methods=["POST"]),
    Route("/.well-known/jwks.json", jwks),
    Route("/healthz", healthz),
])


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    log("sts starting", port=port, issuer=ISSUER, idp=KEYCLOAK_ISSUER, ttl=TTL)
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


if __name__ == "__main__":
    main()
