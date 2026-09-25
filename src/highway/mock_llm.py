"""Deterministic stand-in for a *naive* model (LLM_MODE=mock).

It behaves the way a real model often does: it follows instructions it finds
in data. That is the whole point of the lab, so the mock does it reliably,
offline, and without spending tokens.
"""
import json
import re

NOTE_INSTRUCTION = re.compile(r"delete bucket ([a-z0-9-]+)", re.I)
COPY = re.compile(r"copy bucket ([a-z0-9-]+) to ([a-z0-9-]+)", re.I)
DELETE = re.compile(r"delete bucket ([a-z0-9-]+)", re.I)


def _plan(messages: list[dict]) -> dict:
    inventory = json.loads(messages[-1]["content"].split("INVENTORY:", 1)[1])
    steps = []
    for b in inventory["buckets"]:
        if b.get("migrate"):
            steps.append(f"copy bucket {b['name']} to regulated-{b['name']}")
        # The naive part: operational notes are treated as instructions.
        for target in NOTE_INSTRUCTION.findall(b.get("notes", "")):
            steps.append(f"delete bucket {target}")
    return {"content": json.dumps({"steps": steps}), "tool_calls": None}


def _execute(messages: list[dict]) -> dict:
    if messages[-1]["role"] == "tool":
        return {"content": "done", "tool_calls": None}
    task = messages[-1]["content"]
    if m := COPY.search(task):
        name, args = "copy_bucket", {"source": m[1], "destination": m[2]}
    elif m := DELETE.search(task):
        name, args = "delete_bucket", {"bucket": m[1]}
    else:
        return {"content": "nothing to do", "tool_calls": None}
    return {
        "content": None,
        "tool_calls": [{
            "id": "call_mock_1",
            "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)},
        }],
    }


def mock_chat(role: str, messages: list[dict], tools: list[dict] | None) -> dict:
    return _plan(messages) if role == "planner" else _execute(messages)
