# Part 7: Agent Substrate

Part 6 tested the pattern with a stand-in egress gateway. Part 7 runs the same break and fix against [Agent Substrate](https://github.com/agent-substrate/substrate), the CNCF Sandbox project that ships "zero credentials in the sandbox" as a default.

> **Status: not yet run end to end.** Written on 2026-11-21 from Substrate's docs (pre-1.0, no published release). The first run will probably need fixes. The marked open questions are where. Capture with `task part7:capture` and replace this note with what actually happened.

## What runs

| Lab piece | On Substrate |
|---|---|
| `sandbox-runner` | An **actor** from an `ActorTemplate` on a gVisor `WorkerPool`. No ServiceAccount token, no credentials, no network except through Substrate's egress gateway. |
| Store credential | A Kubernetes Secret served by Substrate's `k8s.io` credential provider, granted to the `highway` atespace. |
| The break | An `EgressPolicy` with `replaceHeaders` + `credentialUri`. The actor sends `Authorization: placeholder`; `atenet-egress` swaps in the store token. |
| The fix | The `EgressPolicy` only allows `store-gate` and injects the **actor's JWT** (`actorJwt`), not the store token. `store-gate` (Part 6's gateway, `CALLER_FROM=actor-jwt`) verifies the actor JWT against Substrate's IdP, checks the permit with OPA, then adds the store token. |
| Permits | `highway.lab_sts`, a stand-in STS (no Keycloak or SPIRE on this cluster). It mints the same claims as Part 3. |

```bash
task part7:up       # kind + Substrate (credential provider on) + store + lab STS + store-gate + the runner actor
task part7:paved    # no EgressPolicy: Part 4's exfil finds no token and no route
task part7:break    # credentialUri: the poisoned cleanup script deletes prod-archive through Substrate
task part7:fix      # actorJwt + store-gate: tester DENIED, ops-admin DENIED (retention lock), no permit DENIED
task part7:down     # delete the kind cluster
```

### Expected (not yet captured)

```text
==> BREAK
list=200 ["customer-data","billing-exports","prod-archive"]
delete=200 {"deleted":"prod-archive"}
==> FIX (tester's permit)
delete=403 {"error":"prod-archive is under retention lock; scope buckets:delete not in permit"}
egress=DENY ... caller=actor/highway/runner-1 sub=tester ...
```

## Prerequisites

- **Linux** (a VM is fine). Substrate needs gVisor (`runsc`) or a Cloud Hypervisor microVM, and plain containers aren't supported. Docker Desktop on Apple Silicon won't run it.
- Docker, kind, kubectl, Go (Substrate installs with `go run ./cmd/ate-setup`), Python 3 with `src/requirements.txt` for `call.py`.
- A recent Kubernetes. Substrate needs the PodCertificateRequest and ClusterTrustBundle APIs; its kind script sets that up.

## Open questions for the first run

1. **Actor image.** Can a gVisor worker pull `highway-agent:dev` after `kind load`, or does it need a registry and a digest (Substrate's example uses `@sha256:`)?
2. **Router to actor.** Does `atenet-router` pass `x-highway-permit` through to the actor, and does the MCP streamable-HTTP session survive actor suspend/resume?
3. **IdP URL.** `run.sh` guesses the JWKS URL from the `ate-system` Service whose name contains `idp`. Set `ACTOR_JWKS_URL` if that's wrong. The JWT `sub` is documented as `actor/<atespace>/<actor-name>`.
4. **Plain HTTP.** The EgressPolicies use `http` rules (no TLS MITM). Substrate decides cleartext on `Host`, method and headers, so `replaceHeaders` should apply, but that's unconfirmed.
5. **`ext_proc`.** The cleaner fix puts the permit check *in* Substrate's egress path via `--experimental-additional-egress-extproc-service`. Its message contract isn't documented yet, so this part uses `store-gate` behind `actorJwt` instead.

## How to use Agent Substrate

**Use it for:** running many untrusted, mostly idle agents on Kubernetes. Thousands of actors are packed onto a few workers and snapshotted out of memory when idle, and Substrate claims resume in under 400 ms. Each actor gets a gVisor or microVM boundary, default-deny egress and a short-lived SPIFFE identity. Credentials are injected outside the sandbox, so a compromised agent has nothing to steal.

**It gives you:**
- Part 2: per-actor workload identity (SPIFFE X.509, or actor JWTs for upstreams)
- Part 4: the fence, as a non-negotiable default
- Part 6: credential injection

**You still build:**
- **Part 3, delegation.** Substrate knows *which actor* is calling, not *which human* started the task or whether that delegation is still valid. Put the permit check at the upstream (as here, behind `actorJwt`) or, once it stabilizes, in an `ext_proc` service. Never grant `credentialUri` for a destination where the credential alone authorizes destructive calls.
- **Part 5, evidence.** Substrate emits structured telemetry (OTLP). Nothing is signed, so feed a tamper-evident store yourself.

**Don't reach for it when** you run a single agent, develop on a Mac, need plain containers, or can't run pre-1.0 infrastructure. Substrate is a CNCF Sandbox project, and CNCF defines that as "not yet widely tested in production".

## Cleanup

```bash
task part7:down
```
