# AGENTS.md

Guidance for AI coding agents working in this repo.

## What this is
Companion labs for a blog series. Every part must **break before it fixes**. Don't "fix" the deliberate vulnerabilities:
- the planner prompt that follows inventory notes,
- the static `LLM_API_KEY`,
- the missing Redis authz.

They're the teaching material for later parts.

## Conventions
- `practice/partN/{README.md, manifests/, run.sh, cleanup.sh, captured/}`. `run.sh <step>` subcommands map 1:1 to `task partN:<step>`.
- Pin versions in `scripts/lib.sh` only. Never use `latest` for control-plane components.
- One image (`src/Dockerfile`). Roles are chosen by `command:` in the manifests.
- Log lines are logfmt-ish (`highway/log.py`) because the posts `grep` them. Keep field names stable: `tool=`, `peer=`, `signer=`, `executor=REJECTED reason=`.
- `LLM_MODE=mock` must stay deterministic. Every lab has to pass offline.

## Checks before committing
```bash
shellcheck -S warning scripts/*.sh practice/*/*.sh
for f in practice/*/manifests/*.yaml; do sed s/SPIRE_VERSION/1.15.3/ $f; echo ---; done | kubeconform -strict -summary -
task --list
scripts/local-smoke.sh start   # then run the planner; see practice/part1/README.md
```

## Lab Verification

Part 1 has been verified against the blog post claims:
- ✅ Plaintext traffic without mesh (8 instruction hits captured)
- ✅ mTLS encryption (0 plaintext hits after mesh with proper restart order)
- ✅ Workload identities secured (all connections SECURED=√)
- ✅ Authenticated workload executes poisoned instructions
- ✅ Logs name workload, not decision-maker

See `LAB-FINDINGS.md` and `part1-verification.md` in the parent directory.

Part 2 infrastructure exists but blocked by SPIRE Kubernetes attestor configuration issue (`registered=false` for agent selectors). Planner signing works; executor verification needs SPIRE fix.

## Commits
Conventional Commits (`feat(part2): ...`, `fix(lib): ...`). Tag each part when its post ships: `part1`, `part2`, ...
