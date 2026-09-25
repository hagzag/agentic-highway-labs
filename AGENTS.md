# AGENTS.md

Guidance for AI coding agents working in this repo.

## What this is
Companion labs for a blog series. Every part must **break before it fixes**. Don't "fix" the deliberate vulnerabilities:
- the planner prompt that follows inventory notes,
- the static `LLM_API_KEY` in Parts 1-2 (Part 3 moves it into `llm-gateway`),
- the missing Redis authz (Part 3's permits ride in the queue; the sender constraint is the defence),
- `mcp-tools:8000` reachable without the gateway (Part 3's ending; Part 4 fences it).

They're the teaching material for later parts.

## Conventions
- `practice/partN/{README.md, manifests/, run.sh, cleanup.sh, captured/}`. `run.sh <step>` subcommands map 1:1 to `task partN:<step>`.
- Pin versions in `scripts/lib.sh` only. Never use `latest` for control-plane components.
- One image (`src/Dockerfile`). Roles are chosen by `command:` in the manifests.
- Log lines are logfmt-ish (`highway/log.py`) because the posts `grep` them. Keep field names stable: `tool=`, `peer=`, `signer=`, `executor=REJECTED reason=`, and from Part 3 `sts=issued|DENY`, `gateway=ALLOW|DENY`, `llm=ALLOW|DENY`, `sub=`, `act=`, `caller=`, `dropped=`.
- New behaviour goes behind a flag that defaults to the previous part's behaviour (`SIGN_PAYLOADS`, `PERMITS`, `LLM_AUTH`, `LOG_SUB`), so earlier labs keep producing their captured output.
- `LLM_MODE=mock` must stay deterministic. Every lab has to pass offline.

## Checks before committing
```bash
shellcheck -S warning scripts/*.sh practice/*/*.sh
for f in practice/*/manifests/*.yaml; do
  sed -e s/SPIRE_VERSION/1.15.3/ -e s/KEYCLOAK_VERSION/26.7.4/ -e s/OPA_VERSION/1.20.1/ $f; echo ---
done | kubeconform -strict -summary -
opa test -v practice/part3/policy
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

## Commits
Conventional Commits (`feat(part2): ...`, `fix(lib): ...`). Tag each part when its post ships: `part1`, `part2`, ...
