# agentic-highway-labs

Hands-on labs for **The Agentic Highway: Cryptographic Trust in the Agentic Era**.

> *mTLS is the highway, not the traffic law.*

Each part runs on a local k3d cluster. Each lab breaks something before it fixes it.

| Part | Post | Lab | Ends with |
|---|---|---|---|
| 1 | The Safe Highway | [practice/part1](practice/part1) — plaintext sniff → Linkerd mTLS → poisoned inventory | An authenticated agent deletes `prod-archive`. The log can't say who asked. |
| 2 | License Plates | [practice/part2](practice/part2) — SPIRE SVIDs → JWS-signed tasks across Redis | Forgery and tampering are rejected. A validly signed bad instruction still runs: identity ≠ permission. |
| 3 | Driving Permits | _coming_ | |
| 4 | The Closed Track | _coming_ | |
| 5 | The Black Box | _coming_ | |

## The cast

| Workload | Role |
|---|---|
| `planner-agent` | Reads the inventory through MCP and asks the model for a plan. Queues one task per step. |
| `executor-agent` | Pops tasks and runs a minimal tool-calling loop against the MCP tools. |
| `mcp-tools` | MCP server (Python SDK 2.x, streamable HTTP) with `list_buckets`, `read_inventory`, `copy_bucket` and `delete_bucket` over a fake object store. |
| `redis` | The broker between the planner and the executor. This is where mTLS ends. |
| `rogue` (Part 2) | A pod in the same namespace with Redis access. It has no SPIRE entry. |

The agent code is plain Python: an agent loop and the MCP SDK, with no framework. See [src/highway](src/highway).

## Prerequisites

- Docker, [k3d](https://k3d.io) ≥ 5.8, kubectl ≥ 1.27 (for `kubectl debug --profile`), [Task](https://taskfile.dev)
- Network access to Docker Hub, `ghcr.io` and `cr.l5d.io`
- ~4 GB RAM free for the cluster

The scripts install the Linkerd CLI themselves if it's missing. Pinned versions are in [scripts/lib.sh](scripts/lib.sh):

- Linkerd `edge-26.9.3` (open-source Linkerd ships edge releases only)
- Gateway API `v1.5.1`
- SPIRE `1.15.3`

## LLM

The agents speak the OpenAI chat-completions API.

```bash
cp .env.example .env         # then edit
set -a; source .env; set +a
```

- `LLM_MODE=mock` (default in the labs) uses a deterministic stand-in for a *naive* model. It follows instructions it finds in data, which is the vulnerability these labs exploit. It runs offline and costs nothing.
- `LLM_MODE=live` calls `LLM_BASE_URL` (default `https://litellm.tikalk.dev`) with `LLM_MODEL` and `LLM_API_KEY`. Any LiteLLM or OpenAI-compatible endpoint works.

The API key is a static Secret mounted into every agent pod. That's on purpose: it's the borrowed credential this series argues against. Part 3 removes it.

## Quick start

```bash
task part1:all      # or step by step: task --list
task part2:all
task down
```

`task partN:capture` runs a part and writes every step's output to `practice/partN/captured/k3d/`. The blog posts quote those files.

## Layout

```
src/                 one image (highway-agent:dev), many roles
  highway/           planner, executor, mcp_tools, broker, signing, forge, mock_llm
practice/partN/      README.md, manifests/, run.sh, cleanup.sh, captured/
scripts/lib.sh       pinned versions + helpers shared by every part
scripts/local-smoke.sh   maintainers: run the agents as processes, no cluster
Taskfile.yml
```

## Disclaimer

This is a teaching lab: no auth on admin routes, `skip_kubelet_verification`, and emptyDir SPIRE storage. Don't copy these manifests into production as-is.
