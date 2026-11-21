# Part 6 on Agent Substrate (mapping, not yet run)

The lab's `egress-gateway` is a small stand-in for the egress gateway Agent Substrate ships (`atenet-egress`). This page maps one onto the other so the Part 6 break and fix can be reproduced on Substrate itself. It's based on Substrate's docs as of 2026-11-19 (pre-1.0, CNCF Sandbox); **nothing here has been run yet**.

| Lab (Part 6) | Agent Substrate |
|---|---|
| `sandbox-runner` pod, no SA token, NetworkPolicy | An actor from an `ActorTemplate` on a `WorkerPool` (`sandboxClasses: gvisor` or `microvm`; plain containers are not supported). "Actors never hold actor identity JWTs/certs, API keys, or cloud tokens." |
| `egress-gateway`, default-deny destinations | `atenet-egress`, the only outbound path; per-actor `EgressPolicy` lists hostnames; non-TCP dropped, DNS filtered |
| `store-token` Secret mounted into the gateway | `--credential-provider='{"name":"k8s.io"}'` + a grant in ConfigMap `k8s-credential-provider-namespace-policy`; the credential is addressed as `ate-secret://k8s.io/default/<ns>/<secret>/<key>` |
| `Authorization: placeholder` replaced with `Bearer <token>` | `EgressPolicy` rule `effects.replaceHeaders` with `credentialUri` (example below) |
| `EGRESS_PERMITS=false`: the break | Substrate's default: the credential goes on for any request the `EgressPolicy` allows |
| `EGRESS_PERMITS=true`: permit check via OPA | **Not built in.** The hook is the experimental `--experimental-additional-egress-extproc-service` (Envoy `ext_proc`, runs after Substrate's own policy, sees headers and actor identity, can deny). The OPA check from `policy/egress.rego` would sit behind it, reading `x-highway-permit`. |
| Signed `egress.decision` in the black box | **Not built in.** Substrate emits structured telemetry (OTLP) for routing events and policy violations; it doesn't sign them. The same `ext_proc` service would emit the signed record before allowing. |
| Runner's Linkerd identity (`l5d-client-id`) | Per-actor short-lived SPIFFE X.509 (about 1 hour); the gateway knows which actor is asking |

## The credential rule (from Substrate's egress-credential-injection guide)

```yaml
# EgressPolicy rule for the store API. The actor sends 'Authorization: placeholder';
# the gateway replaces it. Hostname/port follow your cluster's Service name.
rules:
- http:
    hostnames: ["mcp-tools.migration.svc.cluster.local"]
    effects:
      replaceHeaders:
      - header: Authorization
        prefix: "Bearer "
        credentialUri: ate-secret://k8s.io/default/migration/store-token/token
```

## Steps to reproduce (planned)

1. A Linux host with kind (Substrate's documented dev path): `hack/create-kind-cluster.sh`, then `ATE_INSTALL_KIND=true go run ./cmd/ate-setup deploy ate-system --credential-provider='{"name":"k8s.io"}' ...`.
2. Deploy `mcp-tools` (with `STORE_TOKEN`) and the `store-token` Secret in `migration`; grant the actor's atespace access to `migration` in the provider's namespace policy.
3. Run the runner image as an actor with the rule above. Run the cleanup script: the `DELETE` should succeed through `atenet-egress` (the break).
4. Add an `ext_proc` service that verifies `x-highway-permit` against the STS and asks OPA with `policy/egress.rego`. Re-run: the `DELETE` should be denied (the fix).

Open questions to answer on the first run: what the `ext_proc` request carries for actor identity, whether `ext_proc` can see the `x-highway-permit` header before `replaceHeaders`, and what the gateway logs per allowed request.
