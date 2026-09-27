"""Part 5: the flight recorder's microphone. Each hop signs what it saw and ships it.

    auditlog.emit("gateway.decision", decision="ALLOW", tool="run_script", ...)

The event is a JWS signed with this workload's X.509-SVID (same code as Part 2's
task signing, different `typ`), POSTed to the audit collector. The signature is
the point: the collector, and anyone replaying the log later, can prove *which
workload* wrote each line. A log line on stdout proves nothing of the kind.

AUDIT_URL unset -> emit() is a no-op that returns True (Parts 1-4 behaviour).
A failed emit logs `audit=dropped` and returns False; the caller decides whether
that's fatal (the MCP gateway, with AUDIT_REQUIRED=true, fails closed).
"""
import asyncio
import hashlib
import json

import httpx

from . import config
from .log import log


def digest(obj) -> str:
    """Short, stable fingerprint of anything JSON-able (args, code, output)."""
    raw = obj if isinstance(obj, (bytes, str)) else json.dumps(obj, sort_keys=True, separators=(",", ":"))
    raw = raw.encode() if isinstance(raw, str) else raw
    return hashlib.sha256(raw).hexdigest()[:16]


def emit(kind: str, **fields) -> bool:
    if not config.AUDIT_URL:
        return True
    from . import signing
    event = {"kind": kind, **{k: v for k, v in fields.items() if v not in (None, "", "-")}}
    try:
        token, _ = signing.sign(event, typ=signing.AUDIT_TYP)
        r = httpx.post(f"{config.AUDIT_URL.rstrip('/')}/events", content=token,
                       headers={"content-type": "application/jose"}, timeout=3)
        if r.status_code != 200:
            raise RuntimeError(f"{r.status_code} {r.text[:120]}")
        return True
    except Exception as e:  # noqa: BLE001  the recorder must never crash the flight
        log("audit=dropped", kind=kind, error=f"{type(e).__name__}: {e}")
        return False


async def aemit(kind: str, **fields) -> bool:
    """emit() from async code: the SPIFFE client and the POST are blocking."""
    if not config.AUDIT_URL:
        return True
    return await asyncio.to_thread(emit, kind, **fields)
