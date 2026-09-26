"""Part 4: the sink. Stands in for 'the internet' — somewhere data should never reach.

It lives in its own namespace with no mesh and no relationship to the migration
workloads. If anything in `migration` can POST to it, egress is too open. The
fence (an egress NetworkPolicy) is what makes it unreachable; this server just
records whether the shot got through.
"""
import os

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

from .log import log


async def collect(request: Request) -> JSONResponse:
    body = await request.body()
    log("sink=received", bytes=len(body), src=request.client.host if request.client else "-",
        preview=body[:80].decode("utf-8", "replace").replace("\n", " "))
    return JSONResponse({"received": len(body)})


async def healthz(_: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


app = Starlette(routes=[
    Route("/healthz", healthz),
    Route("/{path:path}", collect, methods=["GET", "POST", "PUT"]),
])


def main() -> None:
    import uvicorn
    port = int(os.environ.get("PORT", "9000"))
    log("sink starting", port=port)
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


if __name__ == "__main__":
    main()
