"""Thin MCP client: list tools as OpenAI function specs, call a tool, get text back."""
import json
from contextlib import asynccontextmanager

from mcp import Client
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

from . import config


def _text(result) -> str:
    if getattr(result, "structured_content", None) is not None:
        return json.dumps(result.structured_content)
    return "\n".join(getattr(c, "text", "") for c in result.content)


async def openai_tools(client: Client) -> list[dict]:
    listed = await client.list_tools()
    return [
        {
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description or "",
                "parameters": t.input_schema,
            },
        }
        for t in listed.tools
    ]


async def call(client: Client, name: str, args: dict) -> str:
    return _text(await client.call_tool(name, args))


@asynccontextmanager
async def connect(permit: str | None = None, url: str | None = None, actor_token: str | None = None):
    """Parts 1-2: plain connection. Part 3: present the permit and a fresh JWT-SVID to the gateway."""
    url = url or config.MCP_URL
    if permit is None:
        async with Client(url) as c:
            yield c
        return
    if actor_token is None:
        from . import svid
        actor_token = svid.token("mcp-gateway")
    headers = {"Authorization": f"Bearer {permit}"}
    if actor_token:
        headers["Actor-Token"] = actor_token
    async with create_mcp_http_client(headers=headers) as http:
        async with Client(streamable_http_client(url, http_client=http)) as c:
            yield c
