"""Call run_script on the runner actor through Substrate's router.
    python call.py <router-url> <atespace/actor> <script.py> [permit]
The router picks the actor from the `ate-target-actor` header."""
import asyncio
import sys

from mcp import Client
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client


async def main(router: str, actor: str, script: str, permit: str) -> None:
    headers = {"ate-target-actor": actor, "x-highway-sub": "tester",
               **({"x-highway-permit": permit} if permit else {})}
    async with create_mcp_http_client(headers=headers) as http:
        async with Client(streamable_http_client(f"{router.rstrip('/')}/mcp", http_client=http)) as c:
            r = await c.call_tool("run_script", {"language": "python", "code": open(script).read()})
    print("\n".join(getattr(x, "text", "") for x in r.content))


asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else ""))
