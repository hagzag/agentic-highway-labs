# Part 8: OpenShell

Part 7 ran the break on Agent Substrate. Part 8 runs it on [OpenShell](https://github.com/NVIDIA/OpenShell) (NVIDIA, CNCF Sandbox), which puts the fence around the process rather than the pod. A supervisor sees every file access, syscall and connection. Credentials are **providers**: the agent's environment holds a placeholder (`openshell:resolve:env:STORE_TOKEN`), and the proxy swaps in the real value only at an approved endpoint.

> **Status: captured 2026-11-22** on macOS (Apple Silicon, Docker Desktop) with OpenShell 0.1.9 from Homebrew. The output is in [`captured/docker/`](captured/docker/).

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

### Captured (2026-11-22, [`captured/docker/`](captured/docker/))

```text
==> PAVED (store provider attached)
env STORE_TOKEN=openshell:resolve:env:v16036625205767672614_STORE_TOKEN
read_token=FileNotFoundError
exfil=URLError [Errno 13] Permission denied

==> BREAK (full access + provider)
list=200 ["customer-data","billing-exports","prod-archive"]
delete=200 {"deleted":"prod-archive"}

==> FIX A (L7 rules)
list=200 ["customer-data","billing-exports","prod-archive"]
delete=HTTPError 403 {"error":"policy_denied","policy":"_provider_highway_store","rule":"DELETE /store/v1/buckets/prod-archive",...}

==> prover vs a read-only boundary
sandbox-break.yaml  result: exceeds_boundary
sandbox-l7.yaml     result: exceeds_boundary  counterexample: ... method=DELETE path=/store/v1/buckets/

==> FIX B (store-gate)
tester:    delete=HTTPError 403 {"error":"prod-archive is under retention lock; scope buckets:delete not in permit"}
ops-admin: delete=HTTPError 403 {"error":"prod-archive is under retention lock"}
egress=DENY method=DELETE host=highway-store:8000 path=/store/v1/buckets/prod-archive caller=- sub=tester ...
```

The prover's result for the L7 policy is the point of that step. The policy blocks `prod-archive`, but `DELETE /store/v1/buckets/*` still lets it delete any *other* bucket, so it isn't read-only. A reviewer reading the YAML can miss that. The prover doesn't.

## What the first run changed

- **Install.** Homebrew's core formula (`brew install openshell`) ships the CLI, `openshell-gateway` and `openshell-prover`, but no gateway service. `run.sh` (`gateway_up`) starts a local gateway on `127.0.0.1:17670` and keeps its state in `.gateway/`. It uses mTLS for the CLI (`openshell-gateway generate-certs`), gateway-minted sandbox JWTs (`OPENSHELL_LOCAL_TLS_DIR`), the docker driver, and `grpc_endpoint = https://host.docker.internal:17670` so sandbox supervisors can reach it. NVIDIA's `install.sh` is still the fallback where there's no Homebrew.
- **Provider profile.** The guessed `location: {header, prefix}` wasn't real. The 0.1.9 schema is `env_vars`, `auth_style: bearer` and `header_name: Authorization`. `profile lint` ignores unknown keys, so a wrong guess still passes lint.
- **Sandbox image.** The sandbox identity needs a WORKDIR it can use, and the highway image's `/app` is root-owned. `run.sh` builds `highway-sandbox:dev`: the same image plus a uid-1000 `sandbox` user with WORKDIR `/sandbox`. `/app` stays read-only.
- **CLI details.**
  - `sandbox delete` takes the name as an argument (`--name` is rejected).
  - Deletion is asynchronous. A sandbox holds its provider, and a provider holds its profile, so `run.sh` waits for the sandbox to go before replacing either.
  - `sandbox create` attaches unless you pass `--detach`.
- **Prover budget.** The L7 candidate needs about 50s of solver time, and at the default 10s it reports `inconclusive (timeout)`. `PROVER_TIMEOUT` defaults to `2m`.

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
