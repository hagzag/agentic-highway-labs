"""Thin MCP client: list tools as OpenAI function specs, call a tool, get text back."""
import json

from mcp import Client

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


def connect() -> Client:
    return Client(config.MCP_URL)
