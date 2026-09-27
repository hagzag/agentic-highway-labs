# Changelog

## [Unreleased]
### Added
- Part 1: k3d + planner/executor/mcp-tools/redis, plaintext sniff, Linkerd `edge-26.9.3` mTLS, poisoned-inventory crash.
- Part 2: SPIRE `1.15.3` (k8s_psat + k8s workload attestor), X.509-SVID-signed JWS tasks across Redis, rogue pod with unsigned, self-signed and tamper attacks, identity ≠ permission ending.
- Part 3: Keycloak `26.7.4` human login, RFC 8693 STS minting permits with nested `act` (JWT-SVID as `actor_token`), MCP gateway (Python PEP + OPA `1.20.1` sidecar PDP), LLM egress gateway (JWT-SVID, holds the only key), stolen-permit and gateway-bypass attacks.
- Part 4: `sandbox-runner` with a code-running `run_script` tool behind the gateway; poisoned-note exfil of the SA token to an off-cluster `sink`; the fence — NetworkPolicy (gateway-only ingress to mcp-tools, DNS-only egress for the runner), `automountServiceAccountToken: false`, and a gVisor (`runsc`) RuntimeClass; a before/after blast-radius probe matrix; best-effort gVisor installer for k3d.
- Part 5: the black box. `highway.auditlog` (every hop signs an audit event with its X.509-SVID), `highway.audit` collector (signer-per-kind ingest check, hash-chained JSONL on a PVC, signed checkpoints anchored in a ConfigMap) and CLI (`verify`, `replay --ip|--bucket|--task-id`, `dump`); gateway fails closed with `AUDIT_REQUIRED`; gateway forwards `x-highway-task`/`x-highway-jti`; forge modes `bypass-framed`, `audit-forge`, `audit-rewrite`; `signing.sign/verify` take a `typ` and a `historic` mode (defaults unchanged).
- Shared agent code: minimal loop, MCP SDK 2.2, LiteLLM/OpenAI-compatible client, deterministic mock LLM.
