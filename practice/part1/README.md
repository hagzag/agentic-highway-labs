# Part 1 — The Safe Highway

Pave the road with mTLS, then watch an authenticated agent crash anyway.

```bash
task part1:up       # k3d + planner, executor, mcp-tools, redis (no mesh)
task part1:sniff    # tcpdump Redis: the plan is plaintext
task part1:mesh     # Gateway API CRDs + Linkerd edge-26.9.3, inject every pod
task part1:edges    # every connection now has an identity on both ends
task part1:sniff    # same sniff: TLS records, no plaintext
task part1:inject   # poison the inventory; executor deletes prod-archive
task part1:key      # the static LLM key every agent carries
```

Or run `task part1:all`. `task part1:capture` does the same and saves each step to `captured/k3d/`.

## What happens

1. **Bumpy road.** The planner calls `read_inventory` over MCP, asks the model for a plan and RPUSHes one task per step into Redis. An ephemeral `netshoot` container in the Redis pod reads every task in cleartext:

   ```text
   RESP "RPUSH" "highway:tasks" "{"task_id": "42", "step": 2, "instruction": "delete bucket prod-archive", "requested_by": "haggai"}"
   ```
   *(real output: [captured/local/sniff-redis.txt](captured/local/sniff-redis.txt))*

2. **Paved road.** Linkerd injects a proxy into every pod.
   - Each proxy gets a certificate for its ServiceAccount, e.g. `executor-agent.migration.serviceaccount.identity.linkerd.cluster.local`.
   - Sniffing `eth0` again shows only TLS records.
   - Sniffing `lo` *inside* the Redis pod still shows plaintext. The mesh decrypts at the proxy.

3. **The crash.** One owner note in the inventory now contains an instruction. The mock model, like many real ones, treats it as part of the job:

   ```text
   planner=step task_id=42 step=2 instruction='delete bucket prod-archive'
   executor=task task_id=42 step=2 instruction='delete bucket prod-archive' requested_by=haggai signer=-
   tool=delete_bucket bucket=prod-archive status=ok peer=-
   ```
   *(real output without a mesh: [captured/local/](captured/local/))*

   With the mesh, `peer=` names the executor's ServiceAccount identity. It names a workload, not a decision:
   - `requested_by=haggai` is a plain string anyone could write.
   - Nothing links the delete to the note that caused it.

## Where mTLS stops
- **Who is driving?** The cert names the vehicle (ServiceAccount), not the human or task it acts for.
- **Where may it go?** Authenticated ≠ authorized per task.
- **What's in the cargo?** TLS ends at every proxy and at the queue. It proves provenance per hop, not intent.

Part 2 gives each vehicle a license plate that survives the queue.

## Cleanup
```bash
./cleanup.sh            # namespace only
./cleanup.sh --cluster  # whole k3d cluster
```
