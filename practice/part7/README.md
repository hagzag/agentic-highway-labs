# Part 7: Agent Substrate

Part 6 tested the pattern with a stand-in egress gateway. Part 7 runs the same break and fix against [Agent Substrate](https://github.com/agent-substrate/substrate), the CNCF Sandbox project that ships "zero credentials in the sandbox" as a default.

> **Status: captured 2026-11-22** on macOS (Apple Silicon) through the Lima VM, kind, and Agent Substrate built from `main`. The output is in [`captured/kind/`](captured/kind/). `doctor.txt` holds the cluster state after the run.

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

### Captured (2026-11-22, [`captured/kind/`](captured/kind/))

```text
==> PAVED: no EgressPolicy yet. Part 4's exfil from inside a gVisor actor
env_store_token=False
read_token=FileNotFoundError
exfil=ConnectError

==> BREAK: grant the store credential (replaceHeaders + credentialUri)
list=200 ["customer-data","billing-exports","prod-archive"]
delete=200 {"deleted":"prod-archive"}
buckets: ['customer-data', 'billing-exports']

==> FIX: tester's permit (no buckets:delete)
delete=403 {"error":"prod-archive is under retention lock; scope buckets:delete not in permit"}
==> ops-admin's permit (holds buckets:delete)
delete=403 {"error":"prod-archive is under retention lock"}
==> no permit
list=403 {"error":"no permit (x-highway-permit)"}
delete=403 {"error":"no permit (x-highway-permit); prod-archive is under retention lock"}

egress=DENY method=DELETE host=mcp-tools.migration.svc.cluster.local:8000 path=/store/v1/buckets/prod-archive caller=actor/highway/runner-1 sub=tester ...
```

The actor never holds the store token, in the break or in the fix. In the break, Substrate's egress gateway adds it to any request for the store. In the fix, store-gate adds it, and only after checking the permit. `caller=actor/highway/runner-1` is the `sub` of the actor JWT that Substrate injected and store-gate verified against Substrate's IdP.

## Prerequisites

- **Linux.** Substrate needs gVisor (`runsc`) or a Cloud Hypervisor microVM, and plain containers aren't supported, so Docker Desktop can't run it.
- **On macOS the tasks handle this.** `task part7:all` installs [Lima](https://lima-vm.io) with Homebrew if it's missing, creates a VM called `highway-substrate` (Ubuntu 24.04, 4 CPU, 8 GiB, from `lima.yaml`), and runs every step inside it. Your checkout is mounted at the same path, so captures land in your repo. The first boot installs Docker, kind, kubectl and Go and takes about 5-10 minutes. `task part7:vm-shell` opens a shell in the VM and `task part7:vm-down` deletes it.
- **On Linux:** Docker, kind, kubectl, Go (Substrate installs with `go run ./cmd/ate-setup`), and Python 3 with `src/requirements.txt` for `call.py`.
- A recent Kubernetes. Substrate needs the PodCertificateRequest and ClusterTrustBundle APIs; its kind script sets that up.

## What the first run answered

1. **Actor image.** A gVisor worker can't use a `kind load`ed image. `run.sh` pushes the image to the kind registry (`localhost:5001`) and pins the actor template to its `@sha256:` digest. When the digest changes, it recreates the template and the actor.
2. **Router to actor.** The router requires a client certificate, so a plain port-forward can't reach it. `kubectl ate proxy actor` mints the certificate. Headers such as `x-highway-permit` and `x-highway-sub` pass through, and the MCP session survives the actor's suspend and resume. `run.sh` starts a fresh proxy for each run, because a proxy left from an earlier run keeps a stale view of the router.
3. **IdP URL.** It's `https://idp.ate-system.svc/openid/v1/jwks`. The serving cert comes from the `servicedns.podcert.ate.dev` signer, so store-gate trusts that signer's ClusterTrustBundle (configmap `idp-ca`). The JWT `sub` is `actor/highway/runner-1`.
4. **Plain HTTP.** `replaceHeaders` works on cleartext `http` rules: the break's `credentialUri` and the fix's `actorJwt` both apply without TLS interception.
5. **gVisor in a Lima VM.** It works. The VM has no `/dev/kvm`, and the gVisor workers run on the `systrap` platform.
6. **`ext_proc`.** Still open. The message contract for `--experimental-additional-egress-extproc-service` isn't documented, so the permit check stays in store-gate behind `actorJwt`.

## Running on a managed Mac

These are things the first run hit on a Mac with VPN and endpoint-security software.

- **Network.** `lima.yaml` uses Apple's NAT (`vzNAT`). Lima's default user-mode network can resolve DNS while TCP is refused.
- **DNS.** The Docker daemon in the VM is pinned to `1.1.1.1` and `8.8.8.8`, and image builds run with `--network=host` (`DOCKER_BUILD_FLAGS`).
- **Router stuck not Ready.** If the `atenet-router` container restarts on its own, for example after a failed liveness probe while the VM slept, its shutdown drains the Envoy sidecar. Envoy stays in `DRAINING`, `/ready` returns 503, and the pod sits at `1/2`. `run.sh` (`router_ready`) spots this and recreates the router pods. By hand: `kubectl -n ate-system delete pod -l app=atenet-router`.
- **Policy timing.** An `EgressPolicy` reaches a running actor asynchronously. `run.sh` waits `EGRESS_SETTLE` seconds (default 10) after changing one, and retries a call while every request still fails with `ConnectError`.
- **Diagnostics.** `task part7:doctor` prints the Substrate pods, router, actor, egress policy, proxy log and node usage. `capture` writes the same to `captured/kind/doctor.txt`, even when a step fails.

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
