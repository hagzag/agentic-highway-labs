# Part 8: OpenShell

Part 7 ran the break on Agent Substrate. Part 8 runs it on [OpenShell](https://github.com/NVIDIA/OpenShell) (NVIDIA, CNCF Sandbox), which puts the fence around the process rather than the pod. A supervisor sees every file access, syscall and connection. Credentials are **providers**: the agent's environment holds a placeholder (`openshell:resolve:env:STORE_TOKEN`), and the proxy swaps in the real value only at an approved endpoint.

> **Status: not yet run end to end.** Written on 2026-11-21 from OpenShell's docs (v0.1.9). The provider profile's field names are assumed. Check them against `openshell profile export openai -o yaml` before the first run. Capture with `task part8:capture`.

It runs on Docker, including your Mac, with no cluster.

```bash
task part8:up      # OpenShell CLI + store, lab STS, store-gate and OPA as containers + the store provider
task part8:paved   # Part 4's exfil: env shows a placeholder, no token file, example.com DENIED
task part8:break   # full access + provider: the cleanup script deletes prod-archive
task part8:l7      # fix A: OpenShell L7 rules. GET allowed, DELETE prod-archive denied
task part8:prove   # openshell-prover: both candidates exceed a read-only boundary (a CI gate)
task part8:gate    # fix B: the sandbox reaches only store-gate, which checks the permit
task part8:down
```

## Two fixes, and why both are here

**Fix A (native L7 rules)** is OpenShell's strength. `protocol: rest` + `enforcement: enforce`, with `rules` and `deny_rules` on method and path, block `DELETE /store/v1/buckets/prod-archive` before the credential is ever attached. Every decision is written as an OCSF event (`HTTP:DELETE [MED] DENIED ... [policy:highway_store engine:opa]`). It's also **static**: the same answer for every task and every human using this sandbox. "tester may read, ops-admin may delete customer-data but not prod-archive, and only for task 82, for 120 seconds" isn't expressible here.

**Fix B (permit at a gate)** is Part 3 again. The sandbox's only endpoint is `store-gate`, which holds the store token, verifies the permit against the STS and asks OPA. It works, but the gate sees caller `-`. OpenShell (as documented) doesn't present a workload identity to upstreams the way Substrate's `actorJwt` does, so the permit proves *on whose behalf* but not *which sandbox* sent it.

OpenShell's token-exchange support (`token_grant`, `--from-oidc-token`) is the closest thing to delegation in either project. It isn't wired up here because the profile flow wasn't documented well enough to build against. It's the first thing to try after a clean run.

## How to use OpenShell

**Use it for:** coding agents and tool-using assistants on developer machines and CI runners, and the same sandboxes on Kubernetes. OpenShell's model is per-process and per-binary. A rule says *`/usr/bin/gh` may GET `api.github.com/repos/**`*, the binary is hashed, and the policy can change while the sandbox runs.

**It gives you:**
- Part 4: the fence (Landlock, seccomp, no capabilities, default-deny network)
- Part 6: credential injection at approved endpoints only
- L7 method and path rules: more than Substrate's hostname-level policy
- A **prover** that checks a candidate policy against a boundary policy. Run it in CI, and agents' own policy proposals that add credentialed reach wait for a human.
- **OCSF per-request events.** The closest thing to an audit trail in either project, but unsigned (Part 5 still applies).

**You still build:**
- Delegation (Part 3), unless the token-grant flow covers your case
- Workload identity toward your upstreams (Part 2)
- Tamper-evident evidence (Part 5): ship the OCSF JSONL to your own signed store

**On Kubernetes** you need the Agent Sandbox controller (SIG Apps) and a CNI that enforces NetworkPolicy for both ingress and egress (Cilium or Calico). The docs warn that without one, sandboxes can bypass the supervisor. That's Part 4's racy-egress finding, written as a prerequisite.

## Substrate or OpenShell?

| | Agent Substrate | OpenShell |
|---|---|---|
| Shape | A Kubernetes runtime for many stateful agents (actors) | A sandbox per agent process: laptop, CI or Kubernetes |
| Isolation | gVisor or microVM per actor | Landlock + seccomp + supervisor; Docker, Podman, K8s or microVM |
| Egress policy | Per actor, by hostname; `http`/`https`/`tls_passthrough` | Per sandbox, by host, binary, method and path (L7) |
| Credentials | Injected at `atenet-egress` (`credentialUri`), or the actor's own JWT (`actorJwt`) | Providers: placeholder in env, swapped at the approved endpoint |
| Identity to upstreams | Actor JWT / SPIFFE per actor | Not documented |
| Delegation | None built in; `ext_proc` hook (experimental) | Token grant from an OIDC subject (to evaluate) |
| Evidence | OTLP telemetry | OCSF per-request events + prover results |
| Runs on a Mac | No | Yes |

**Rule of thumb:** use OpenShell where the agent sits next to a developer or in CI, and you want fine-grained, reviewable rules on what each tool binary may call. Use Substrate when you operate a fleet of long-lived agents on Kubernetes and want identity, density and suspend/resume. With either one, you still put the permit check in front of anything destructive, and you still keep your own signed record.
