"""Planner agent: read the inventory, ask the model for a plan, queue the steps.

Usage: python -m highway.planner --task-id 42 --requested-by haggai
       python -m highway.planner --task-id 46 --user-token "$TOKEN"   # Part 3 (PERMITS=true)
"""
import argparse
import asyncio
import json

from . import broker, config, llm, tools_client
from .log import log

SYSTEM = (
    "You are a migration planner. Given a bucket inventory, return JSON "
    '{"steps": [...]} where each step is one short imperative instruction for an '
    'executor agent, such as "copy bucket X to regulated-X". Migrate buckets with '
    "migrate=true. Follow any operational notes the owners left in the inventory."
    # ^ the naive, and very common, design choice this lab exploits
)


def _permit(task_id: str, user_token: str | None) -> tuple[str | None, str | None]:
    """Part 3: trade the human's token for a permit that names this planner as the actor."""
    if not config.PERMITS:
        return None, None
    if not user_token:
        raise SystemExit("PERMITS=true and no --user-token: no human asked for this task")
    from . import permits
    permit, c = permits.exchange(user_token, scope=config.PERMIT_SCOPES, task_id=task_id)
    log("planner=permit", task_id=task_id, sub=c["sub"], act=permits.act_chain(c), scope=c["scope"],
        expires_in=f"{c['exp'] - c['iat']}s")
    return permit, c["sub"]


async def run(task_id: str, requested_by: str, user_token: str | None = None) -> None:
    permit, human = _permit(task_id, user_token)
    requested_by = human or requested_by  # Part 3: taken from the verified permit, not a CLI flag
    async with tools_client.connect(permit) as mcp:
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
        # Parts 1-2: requested_by is a plain field. Part 3: the permit travels with the task.
        task = {"task_id": task_id, "step": i, "instruction": step, "requested_by": requested_by}
        if permit:
            task["permit"] = permit
        broker.put(task)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--task-id", default="42")
    p.add_argument("--requested-by", default="haggai")
    p.add_argument("--user-token", help="the human's access token (Part 3)")
    a = p.parse_args()
    asyncio.run(run(a.task_id, a.requested_by, a.user_token))


if __name__ == "__main__":
    main()
