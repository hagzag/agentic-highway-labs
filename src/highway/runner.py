"""Part 4: the sandbox-runner. An MCP tool that runs a short script.

This is the high-blast-radius tool the whole part is about. `run_script` executes
code the model chose. In the lab it runs a small Python snippet in-process and
deterministically (LLM_MODE=mock), but the point stands: a tool that runs code
inherits its pod's blast radius — its ServiceAccount token, and every network
path the pod can open. Part 4 shrinks that radius from the outside:
NetworkPolicy, no mounted token, and a gVisor sandbox.

The runner sits behind the same MCP gateway as mcp-tools, so `run_script` is
subject to the same permit + policy checks (scope `scripts:run`).
"""
import io
import os
import contextlib
import socket

from starlette.requests import Request
from starlette.responses import JSONResponse

from mcp.server.mcpserver import Context, MCPServer

import httpx

from . import auditlog, config
from .log import log

mcp = MCPServer("highway-runner", log_level="WARNING")

# Part 6: the permit of the run_script call in progress (scripts run one at a time).
_CALL_PERMIT = ""


def egress(method: str, url: str, body: bytes | None = None) -> str:
    """Part 6: the script's only road out. Goes through the egress gateway, which
    adds the credential the script never holds. "placeholder" is all it can send.

        egress("DELETE", "http://mcp-tools:8000/store/v1/buckets/prod-archive")
    """
    if not config.EGRESS_URL:
        return "no egress gateway (EGRESS_URL unset)"
    target = url.split("://", 1)[-1]
    headers = {"authorization": "placeholder"}
    if _CALL_PERMIT:
        headers["x-highway-permit"] = _CALL_PERMIT
    try:
        r = httpx.request(method, f"{config.EGRESS_URL.rstrip('/')}/{target}", content=body,
                          headers=headers, timeout=10)
        return f"{r.status_code} {r.text.strip()[:160]}"
    except Exception as e:  # noqa: BLE001
        return type(e).__name__


def _peer(ctx: Context) -> str:
    h = ctx.headers or {}
    return h.get("x-highway-sub", h.get("l5d-client-id", "-"))


@mcp.tool()
def run_script(code: str, ctx: Context, language: str = "python") -> str:
    """Run a short diagnostic script and return its stdout. language: python."""
    sub = _peer(ctx)
    log("runner=run_script", language=language, bytes=len(code), sub=sub)
    if language != "python":
        return f"unsupported language {language}"
    global _CALL_PERMIT
    _CALL_PERMIT = (ctx.headers or {}).get("x-highway-permit", "")
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            # The sandbox is the pod, not this exec(): the lab constrains the pod
            # from outside (NetworkPolicy, no token, gVisor), never the interpreter.
            exec(code, {"__name__": "__runner__", "os": os, "egress": egress})  # noqa: S102  lab-only, deliberate
    except Exception as e:  # noqa: BLE001  report, don't crash the server
        out = buf.getvalue()
        log("runner=error", sub=sub, error=f"{type(e).__name__}: {e}")
        _record(ctx, code, language, "error", f"{out}\nerror: {type(e).__name__}: {e}")
        return f"{out}\nerror: {type(e).__name__}: {e}"
    out = buf.getvalue().strip()
    log("runner=done", sub=sub, out_bytes=len(out), out=out.replace("\n", " | ")[:300])
    _record(ctx, code, language, "ok", out)
    return out or "(no output)"


def _pod_ip() -> str:
    return os.environ.get("POD_IP") or socket.gethostbyname(socket.gethostname())


def _record(ctx: Context, code: str, language: str, status: str, out: str) -> None:
    """Part 5: what ran, for whom (claimed), from which pod IP, and what came out.
    pod_ip is the join key for an off-cluster report ("the sink saw src=...")."""
    h = ctx.headers or {}
    auditlog.emit("runner.exec", language=language, status=status, code=auditlog.digest(code),
                  code_bytes=len(code), out=out[:240], out_digest=auditlog.digest(out),
                  sub=h.get("x-highway-sub"), act=h.get("x-highway-act"), task_id=h.get("x-highway-task"),
                  jti=h.get("x-highway-jti"), peer=h.get("l5d-client-id"), pod_ip=_pod_ip())


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


def main() -> None:
    port = int(os.environ.get("PORT", "8000"))
    log("sandbox-runner starting", port=port)
    mcp.run("streamable-http", host="0.0.0.0", port=port, stateless_http=True, json_response=True)


if __name__ == "__main__":
    main()
