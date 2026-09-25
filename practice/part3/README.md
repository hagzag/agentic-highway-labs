# Part 3 — Driving Permits

Part 2 ended with a validly signed `delete bucket prod-archive` that no human asked for. Identity isn't permission. This lab adds the permission part: a **permit for this trip only**.

- **Delegation, not impersonation.** The human logs in to Keycloak. Each agent swaps the token it holds for a narrower one at a small RFC 8693 STS, and proves who it is with its **JWT-SVID** (`actor_token`). The permit says `sub` = the human, `act` = the chain of agents (`executor-agent via planner-agent`), `scope` = requested ∩ what the human holds ∩ what the agent may carry, and it expires in 120 s.
- **Policy at the MCP gateway.** A Python PEP verifies the permit *and* the presenter's JWT-SVID. OPA (PDP, sidecar on localhost) decides the call: tool → scope, sender constraint (`caller == act.sub`), which agent may call which tool, and resource rules no scope overrides (a retention lock on `prod-archive`).
- **No LLM key in the agents.** The static `LLM_API_KEY` moves into `llm-gateway`, the only pod that mounts it. Agents authenticate with a JWT-SVID (`aud=llm-gateway`). `LLM_MODE=mock` still runs offline: the gateway serves the mock.

```bash
task part3:up       # Part 2 road (signing ON) + Keycloak 26.7.4 + STS + MCP gateway (OPA 1.20.1) + LLM gateway
task part3:key      # BREAK: both agent pods carry the static LLM key
task part3:llm-gw   # FIX: key only in llm-gateway; agents use their SVID; rogue gets 401
task part3:login    # a human logs in; what's in the Keycloak token
task part3:permit   # FIX: delegation ON. Token exchange per hop; gateway ALLOWs; the permit, decoded
task part3:poison   # Part 2's ending replayed: the delete is DENIED at the gateway
task part3:admin    # ops-admin holds buckets:delete; retention lock still DENIES
task part3:steal    # rogue lifts a permit from Redis; useless without the executor's SVID
task part3:bypass   # BREAK AGAIN: rogue calls mcp-tools directly and the delete works
```

Log in as someone else with `LAB_USER=hagzag task part3:permit`. Realm users (password = username, lab only): `hagzag` and `tester` hold `migrator` (read, copy). `ops-admin` also holds `storage-admin` (delete).

## Real output (local processes: SPIRE 1.15.3, Keycloak 26.7.4, OPA 1.20.1)

From [captured/local/driver.log](captured/local/driver.log). On k3d the same lines appear in the pods' logs.

```text
# The planner asks for everything. The STS trims it to what tester holds.
sts=issued sub=tester act=planner-agent scope='buckets:copy buckets:read' dropped=buckets:delete ttl=120 task_id=46
sts=issued sub=tester act='executor-agent via planner-agent' scope='buckets:copy buckets:read' dropped=- ttl=119 task_id=46
gateway=ALLOW tool=copy_bucket sub=tester act='executor-agent via planner-agent' caller=executor-agent task_id=46 ...

# Part 2's ending: same poisoned note, same valid signature. Different outcome.
executor=task task_id=47 step=2 instruction='delete bucket prod-archive' requested_by=tester signer=spiffe://highway.lab/ns/migration/sa/planner-agent
gateway=DENY method=tools/call tool=delete_bucket sub=tester act='executor-agent via planner-agent' caller=executor-agent task_id=47 reason='prod-archive is under retention lock; scope buckets:delete not in permit'

# Even a human who holds delete can't delete what policy protects.
gateway=DENY method=tools/call tool=delete_bucket sub=ops-admin ... reason='prod-archive is under retention lock'

# A permit lifted from the queue is useless without the actor's SVID.
forge=stolen task_id=49 sub=tester act=planner-agent scope='buckets:copy buckets:read'
gateway=DENY method=initialize tool=- sub=tester act=planner-agent caller=- task_id=49 reason='no actor token (JWT-SVID)'

# ...but nothing forces traffic through the gate.
forge=bypass target=http://127.0.0.1:8000/mcp result='{"result": "deleted prod-archive"}'
tool=delete_bucket bucket=prod-archive status=ok peer=- sub=-
```

## The permit

```text
Keycloak token (tester)  ──┐
planner JWT-SVID (aud=sts) ─┴─► STS ─► permit  sub=tester  act={planner-agent}                         scope=read copy  exp=+120s
executor JWT-SVID (aud=sts) ──────► STS ─► permit  sub=tester  act={executor-agent, act={planner-agent}} scope ⊆ above   exp ≤ above
executor: Authorization: Bearer <permit> + Actor-Token: <JWT-SVID aud=mcp-gateway> ─► mcp-gateway ─► OPA ─► mcp-tools
```

- **Each hop can narrow a permit, never widen it.** Scope is an intersection. `exp` is `min(now + TTL, upstream exp)`.
- **`may_act` lives in the STS.** `ACTORS` in [sts.py](../../src/highway/sts.py) says the planner may act for humans and the executor may act only for the planner.
- **Sender-constrained.** The gateway requires a JWT-SVID from the agent named in `act.sub`. The permit rides in the queue; Redis still has no authz (on purpose). So the permit is readable, but not usable by anyone else.

## Why a lab STS and not Keycloak's token exchange?
Keycloak 26.7.4 supports standard token exchange (RFC 8693) for audience and scope downscoping. **Delegation** (`actor_token`, `act`) is `token-exchange-delegation`, which is *experimental*: single-hop (multi-hop is planned for 26.8), and designed for admin impersonation (it needs the `impersonation` role and a consent screen). SPIFFE client authentication is *preview* (`spiffe:v1`). The ~150-line [sts.py](../../src/highway/sts.py) shows the moving parts, stays vendor-neutral, and produces the multi-hop `act` chain Part 5 needs for audit.

## Policy
[policy/mcp.rego](policy/mcp.rego) + [policy/data.json](policy/data.json), with tests:

```bash
opa test -v practice/part3/policy
```

## What this didn't fix
The permit is checked **at the gate**. `mcp-tools:8000` is still reachable from any pod in the namespace. The rogue skips the gateway, and the delete succeeds with `sub=-`. Part 4, The Closed Track, adds the fence: egress NetworkPolicy, a sandboxed runtime, and a blast-radius report.

## Cleanup
```bash
./cleanup.sh            # idp namespace + everything Part 2 installed
./cleanup.sh --cluster  # whole k3d cluster
```
