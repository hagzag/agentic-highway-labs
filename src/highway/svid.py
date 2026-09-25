"""Part 3: JWT-SVIDs. The agent's SPIRE identity as a short-lived bearer for one audience.

Part 2 used the X.509-SVID to sign payloads. Here the same identity shows up as a
JWT-SVID: a token SPIRE mints for exactly one audience (the STS, the MCP gateway,
the LLM gateway). No client secret, no API key, nothing to copy into a Secret.
"""
from spiffe import WorkloadApiClient

from . import config


def _client() -> WorkloadApiClient:
    return WorkloadApiClient(config.SPIFFE_ENDPOINT_SOCKET)


def token(audience: str) -> str:
    """A JWT-SVID for `audience`, fetched from the local SPIRE agent."""
    with _client() as c:
        return c.fetch_jwt_svid(audience={audience}).token


def validate(tok: str, audience: str) -> str:
    """Return the caller's SPIFFE ID, or raise. Checks signature, expiry and audience."""
    with _client() as c:
        return str(c.validate_jwt_svid(tok, audience).spiffe_id)


def short(spiffe_id: str | None) -> str:
    """spiffe://highway.lab/ns/migration/sa/planner-agent -> planner-agent (for log lines)."""
    return spiffe_id.rsplit("/", 1)[-1] if spiffe_id else "-"
