"""Planner agent: read the inventory, ask the model for a plan, queue the steps.

Usage: python -m highway.planner --task-id 42 --requested-by haggai
"""
import argparse
import asyncio
import json

from . import broker, llm, tools_client
from .log import log

SYSTEM = (
    "You are a migration planner. Given a bucket inventory, return JSON "
    '{"steps": [...]} where each step is one short imperative instruction for an '
    'executor agent, such as "copy bucket X to regulated-X". Migrate buckets with '
    "migrate=true. Follow any operational notes the owners left in the inventory."
    # ^ the naive, and very common, design choice this lab exploits
)


async def run(task_id: str, requested_by: str) -> None:
    async with tools_client.connect() as mcp:
        inventory = json.loads(await tools_client.call(mcp, "read_inventory", {}))
    reply = llm.chat("planner", [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": "INVENTORY:" + json.dumps(inventory)},
    ])
    text = reply["content"].strip().removeprefix("```json").removesuffix("```")
    steps = json.loads(text)["steps"]
    log("planner=plan", task_id=task_id, steps=len(steps))
    for i, step in enumerate(steps, 1):
        log("planner=step", task_id=task_id, step=i, instruction=step)
        # requested_by travels as a plain field. Nothing binds it to a human yet (Part 3).
        broker.put({"task_id": task_id, "step": i, "instruction": step, "requested_by": requested_by})


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--task-id", default="42")
    p.add_argument("--requested-by", default="haggai")
    a = p.parse_args()
    asyncio.run(run(a.task_id, a.requested_by))


if __name__ == "__main__":
    main()
