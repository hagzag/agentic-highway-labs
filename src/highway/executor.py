"""Executor agent: pop a task, run a minimal tool-calling loop against MCP tools."""
import asyncio
import json
import time

from . import broker, config, llm, tools_client
from .log import log

SYSTEM = (
    "You are a migration executor. Carry out the instruction using the tools. "
    "Call exactly the tools needed, then reply 'done'."
)
MAX_TURNS = 5


def _permit(task: dict) -> str | None:
    """Part 3: exchange the planner's permit for one that names this executor (act nests)."""
    if not config.PERMITS:
        return None
    from . import permits
    if "permit" not in task:
        raise permits.Refused("task carries no permit")
    permit, c = permits.exchange(task["permit"], task_id=str(task["task_id"]))
    log("executor=permit", task_id=task["task_id"], step=task["step"], sub=c["sub"],
        act=permits.act_chain(c), scope=c["scope"], expires_in=f"{c['exp'] - c['iat']}s")
    return permit


async def handle(task: dict, permit: str | None) -> None:
    async with tools_client.connect(permit) as mcp:
        tools = await tools_client.openai_tools(mcp)
        messages = [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": task["instruction"]},
        ]
        for _ in range(MAX_TURNS):
            reply = llm.chat("executor", messages, tools)
            calls = reply.get("tool_calls") or []
            messages.append({"role": "assistant", "content": reply.get("content"), "tool_calls": calls or None})
            if not calls:
                break
            for call in calls:
                name = call["function"]["name"]
                args = json.loads(call["function"]["arguments"] or "{}")
                log("executor=tool_call", task_id=task["task_id"], step=task["step"], tool=name, args=json.dumps(args))
                result = await tools_client.call(mcp, name, args)
                if result.startswith("DENIED"):
                    log("executor=denied", task_id=task["task_id"], step=task["step"], tool=name, result=result)
                messages.append({"role": "tool", "tool_call_id": call["id"], "content": result})


def main() -> None:
    from .permits import Refused
    from .signing import Rejected  # cheap import; only used when VERIFY_PAYLOADS=true

    log("executor starting")
    while True:
        try:
            got = broker.get()
        except Rejected as e:
            log("executor=REJECTED", reason=str(e))
            continue
        except Exception as e:  # noqa: BLE001  broker not ready yet, etc.
            log("executor=error", error=f"{type(e).__name__}: {e}")
            time.sleep(2)
            continue
        if got is None:
            continue
        task, signer = got
        try:
            permit = _permit(task)
        except Refused as e:
            log("executor=REJECTED", task_id=task.get("task_id"), reason=f"permit: {e}")
            continue
        except Exception as e:  # noqa: BLE001  STS or SPIRE unreachable
            log("executor=error", task_id=task.get("task_id"), error=f"permit: {type(e).__name__}: {e}")
            continue
        log("executor=task", task_id=task["task_id"], step=task["step"],
            instruction=task["instruction"], requested_by=task.get("requested_by", "-"), signer=signer)
        try:
            asyncio.run(handle(task, permit))
        except Exception as e:  # noqa: BLE001  one bad task must not kill the loop
            log("executor=error", task_id=task["task_id"], error=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
