# AGENTS.md

Guidance for AI coding agents working in this repo.

## What this is
Companion labs for a blog series. Every part must **break before it fixes**. Don't "fix" the deliberate vulnerabilities:
- the planner prompt that follows inventory notes,
- the static `LLM_API_KEY` in Parts 1-2 (Part 3 moves it into `llm-gateway`),
- the missing Redis authz (Part 3's permits ride in the queue; the sender constraint is the defence),
- `mcp-tools:8000` reachable without the gateway (Part 3's ending; Part 4 fences it),
- the `x-highway-sub` header trusted by mcp-tools/sandbox-runner logs (Part 5's framed bypass; the audit replay shows why a header is a claim, not proof),
- Part 5 runs with Part 4's fence *off*: the black box records the crash.
- Part 6's `EGRESS_PERMITS=false` default: the egress gateway injects the credential for any allowed destination. That's the break (and what sandbox runtimes do out of the box).

They're the teaching material for later parts.

## Conventions
- `practice/partN/{README.md, manifests/, run.sh, cleanup.sh, captured/}`. `run.sh <step>` subcommands map 1:1 to `task partN:<step>`.
- Pin versions in `scripts/lib.sh` only. Never use `latest` for control-plane components.
- One image (`src/Dockerfile`). Roles are chosen by `command:` in the manifests.
- Log lines are logfmt-ish (`highway/log.py`) because the posts `grep` them. Keep field names stable: `tool=`, `peer=`, `signer=`, `executor=REJECTED reason=`, and from Part 3 `sts=issued|DENY`, `gateway=ALLOW|DENY`, `llm=ALLOW|DENY`, `sub=`, `act=`, `caller=`, `dropped=`, and from Part 4 `runner=run_script|done`, `sink=received`, `probe target= result=REACH|BLOCKED|NODNS`, and from Part 5 `audit=appended|REJECTED|checkpoint|dropped`, `verify ... verdict=INTACT|TAMPERED`, `forge=audit-forged|audit-rewrite`, and the replay's `VERDICT` block, and from Part 6 `egress=INJECT|DENY|upstream_error`, `store=list|delete|DENY`.
- New behaviour goes behind a flag that defaults to the previous part's behaviour (`SIGN_PAYLOADS`, `PERMITS`, `LLM_AUTH`, `LOG_SUB`, Part 4's `UPSTREAM_RUNNER_URL` on the gateway, and Part 5's `AUDIT_URL` / `AUDIT_REQUIRED`: unset = no audit events, Part 6's `STORE_TOKEN` / `FORWARD_PERMIT` / `EGRESS_URL` / `EGRESS_PERMITS`), so earlier labs keep producing their captured output.
- `LLM_MODE=mock` must stay deterministic. Every lab has to pass offline.

## Checks before committing
```bash
shellcheck -S warning scripts/*.sh practice/*/*.sh
for f in practice/*/manifests/*.yaml; do
  sed -e s/SPIRE_VERSION/1.15.3/ -e s/KEYCLOAK_VERSION/26.7.4/ -e s/OPA_VERSION/1.20.1/ $f; echo ---
done | kubeconform -strict -summary -
opa test -v practice/part3/policy
opa test -v practice/part6/policy
task --list
scripts/local-smoke.sh start   # then run the planner; see practice/part1/README.md
```

## Lab Verification

**Part 1** has been fully verified against the blog post claims:
- ✅ Plaintext traffic without mesh (8 instruction hits captured)
- ✅ mTLS encryption (0 plaintext hits after mesh with proper restart order)
- ✅ Workload identities secured (all connections SECURED=√)
- ✅ Authenticated workload executes poisoned instructions
- ✅ Logs name workload, not decision-maker

**Part 2** has been fully verified with SPIRE working:
- ✅ Agents fetch valid X.509-SVIDs from SPIRE Workload API
- ✅ Planner signs payloads with SPIFFE-bound certificates
- ✅ Unsigned and self-signed forgeries rejected by executor
- ✅ Queue tampering (rewriting signed messages) detected and rejected
- ✅ Poisoned inventory demonstrates signature ≠ authorization (demonstrates need for Part 3)

SPIRE note: there is no `WorkloadAPIServer` block (SPIRE crashes on it). Early PERMISSION_DENIED was entry-sync timing; `wait_svid` handles it.

**Part 3** verified as local processes (SPIRE 1.15.3 unix attestation, Keycloak 26.7.4, OPA 1.20.1), see `practice/part3/captured/local/`. k3d capture pending:
- ✅ STS trims the planner's greedy scope to the human's roles (`dropped=buckets:delete`)
- ✅ Multi-hop `act` chain: `executor-agent via planner-agent`; exp never extends across hops
- ✅ Poisoned delete DENIED at the gateway (scope + retention lock); ops-admin still DENIED (retention lock)
- ✅ Stolen permit DENIED (no actor JWT-SVID); rogue DENIED at llm-gateway
- ✅ Bypass: direct call to mcp-tools deletes `prod-archive` with `sub=-` (sets up Part 4)

See detailed findings in `../LAB-FINDINGS.md` and `../part1-verification.md`.

**Part 5** verified on k3d 2026-09-27 (fresh cluster, `task down && task part5:capture`), see `practice/part5/captured/k3d/`:
- ✅ Break: the sink's src IP maps to the runner pod, whose log has `sub=tester` and nothing else; the framed bypass logs `sub=hagzag` (0 permits ever issued to hagzag); after a restart the runner's log and pod IP are gone
- ✅ Task 71 records 19 signed events across sts, planner, executor, gateway, mcp-tools, sandbox-runner; checkpoint anchored in the ConfigMap
- ✅ `replay --ip` (sink src = runner pod IP) names tester, `executor-agent via planner-agent`, task 71, permit lineage, the poisoned note; `did: read_token bytes=1228 kube_api=200 exfil=200`
- ✅ `replay --bucket prod-archive`: human UNPROVEN, no gateway decision, caller `rogue` from Linkerd's mTLS peer
- ✅ Unsigned and self-signed (claims mcp-gateway) events rejected at ingest
- ✅ Insider rewrite + rechain: `sig=BAD` at seq 13, checkpoint MISMATCH, verdict TAMPERED; replay ignores the bad record and still names tester
- ✅ Collector at 0 replicas + `AUDIT_REQUIRED=true`: `audit=dropped` then gateway DENY `audit unavailable`
- Fix found on the way: re-running `part3 up` on a reused cluster left `highway-permits` patched (MCP_URL=gateway); `up` now resets it.

**Part 6** verified as local processes 2026-11-21 (`task part6:local`, `practice/part6/captured/local/`); **not yet run on k3d** (`task part6:capture` pending):
- ✅ The store refuses a call without the credential; the sandbox has neither the SA token nor `STORE_TOKEN`
- ✅ Break (`EGRESS_PERMITS=false`): the poisoned cleanup script's `DELETE` goes through the egress gateway, `egress=INJECT ... sub=-`, `prod-archive` deleted; the sink stays default-deny
- ✅ Fix (`EGRESS_PERMITS=true`): tester's permit → DENY `prod-archive is under retention lock; scope buckets:delete not in permit`; ops-admin's permit → DENY (retention lock); no permit → DENY
- ✅ `opa test practice/part6/policy`: 6/6
- Local runs have no mesh, so the local policy data adds caller `-`; on k3d the caller is Linkerd's `l5d-client-id`.

## Commits
Conventional Commits (`feat(part2): ...`, `fix(lib): ...`). Tag each part when its post ships: `part1`, `part2`, ...
