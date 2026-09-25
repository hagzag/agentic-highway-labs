"""Part 3: the agent side of delegation. Swap what you hold for a narrower permit.

RFC 8693 token exchange against the lab STS:
  subject_token = who the work is for (the human's Keycloak token, or an upstream permit)
  actor_token   = who is doing it (this agent's JWT-SVID, audience "sts")
The STS answers with a permit: sub = the human, act = the chain of agents, a
scope no wider than the human holds, and a TTL measured in seconds.
"""
import base64
import json

import httpx

from . import config, svid

GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
ACCESS_TOKEN = "urn:ietf:params:oauth:token-type:access_token"
JWT = "urn:ietf:params:oauth:token-type:jwt"


class Refused(Exception):
    """The STS said no. The message is its error_description."""


def exchange(subject_token: str, scope: str | None = None, task_id: str | None = None,
             audience: str = "mcp-gateway") -> tuple[str, dict]:
    """Return (permit, its claims)."""
    form = {
        "grant_type": GRANT,
        "subject_token": subject_token,
        "subject_token_type": ACCESS_TOKEN,
        "actor_token": svid.token("sts"),
        "actor_token_type": JWT,
        "audience": audience,
    }
    if scope:
        form["scope"] = scope
    if task_id:
        form["task_id"] = task_id
    resp = httpx.post(f"{config.STS_URL.rstrip('/')}/token", data=form, timeout=10)
    body = resp.json()
    if resp.status_code != 200:
        raise Refused(body.get("error_description") or body.get("error") or resp.text)
    return body["access_token"], claims(body["access_token"])


def claims(token: str) -> dict:
    """Decode a JWT's claims WITHOUT verifying it. For logging only."""
    body = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))


def act_chain(c: dict) -> str:
    """{'act': {'sub': executor, 'act': {'sub': planner}}} -> 'executor-agent via planner-agent'."""
    names, act = [], c.get("act")
    while act:
        names.append(svid.short(act.get("sub")))
        act = act.get("act")
    return " via ".join(names) or "-"
