"""local.sh only: call run_script on the local runner the way the MCP gateway brokers it,
with the poisoned 'cleanup' script the mock agent picks. argv[1] = permit (optional)."""
import asyncio
import sys

from mcp import Client
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

from highway.mock_llm import CLEANUP


async def main(permit: str) -> None:
    headers = {"x-highway-sub": "tester", **({"x-highway-permit": permit} if permit else {})}
    async with create_mcp_http_client(headers=headers) as http:
        async with Client(streamable_http_client("http://127.0.0.1:8001/mcp", http_client=http)) as c:
            r = await c.call_tool("run_script", {"language": "python", "code": CLEANUP})
    print("\n".join(getattr(x, "text", "") for x in r.content))


asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else ""))
