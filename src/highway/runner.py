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

from starlette.requests import Request
from starlette.responses import JSONResponse

from mcp.server.mcpserver import Context, MCPServer

from .log import log

mcp = MCPServer("highway-runner", log_level="WARNING")


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
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            # The sandbox is the pod, not this exec(): the lab constrains the pod
            # from outside (NetworkPolicy, no token, gVisor), never the interpreter.
            exec(code, {"__name__": "__runner__", "os": os})  # noqa: S102  lab-only, deliberate
    except Exception as e:  # noqa: BLE001  report, don't crash the server
        out = buf.getvalue()
        log("runner=error", sub=sub, error=f"{type(e).__name__}: {e}")
        return f"{out}\nerror: {type(e).__name__}: {e}"
    out = buf.getvalue().strip()
    log("runner=done", sub=sub, out_bytes=len(out))
    return out or "(no output)"


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


def main() -> None:
    port = int(os.environ.get("PORT", "8000"))
    log("sandbox-runner starting", port=port)
    mcp.run("streamable-http", host="0.0.0.0", port=port, stateless_http=True, json_response=True)


if __name__ == "__main__":
    main()
