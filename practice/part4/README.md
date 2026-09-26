# Part 4 — The Closed Track

Part 3 ended with a pod that skipped the gateway and deleted a bucket. The permit was checked *at the gate*; nothing forced traffic through the gate. Part 4 builds the fence, around the worst tool in the system: one that runs code.

- **The blast radius is the pod's, not the tool's.** `run_script` (a new MCP tool in a `sandbox-runner` pod, behind the same gateway) runs whatever the model chose. Policy can say *who* may call it; it can't shrink what the running code can reach. That's set by the pod: its ServiceAccount token, and every network path it can open.
- **The fence is three cuts, from outside the process:**
  1. **NetworkPolicy** — the gateway is the only road to `mcp-tools` (closes Part 3's bypass), and the runner may egress only DNS + the mesh control plane (so it can't reach the kube API or the internet).
  2. **No token** — `automountServiceAccountToken: false`. The app loses its token; Linkerd keeps its own projected identity token, so the mesh still works.
  3. **gVisor** — the runner runs under `runsc`, a user-space kernel, so a container escape lands in gVisor, not the host.
- **A blast-radius report** — the same probe runs from every pod, before and after, to `mcp-tools`, the kube API and the sink. The table *is* the proof the fence bit.

```bash
task part4:up            # Part 3 road + sink (the "internet") + sandbox-runner, no fence
task part4:probe-before  # blast-radius matrix: runner reaches the sink and the kube API
task part4:break         # bypass still works; a poisoned note runs a script that steals the SA token to the sink
task part4:gvisor        # best-effort runsc install on the k3d node (optional; see below)
task part4:fence         # NetworkPolicy + no token + gVisor
task part4:verify        # the bypass is dead; the exfil finds no token and no route out
task part4:probe-after   # same matrix, now all BLOCKED
```

## The break (real output, k3d)

The poisoned inventory note from Parts 1–3, one more turn of the screw: instead of "delete a bucket", it says "run the diagnostics script". The naive agent does.

```text
runner=run_script language=python bytes=... sub=tester
# the script, inside the runner pod, on runc with its token mounted:
read_token bytes=1043        # the pod's ServiceAccount token
kube_api=200                 # used it against the Kubernetes API
exfil=200                    # and shipped it off-cluster
sink=received bytes=1043 src=... preview=eyJhbGciOi...   # the sink caught the token
```

## The fence (real output, k3d)

Same poisoned note, same allowed `run_script`. The policy still says yes — this isn't a policy fix. What changed is the pod:

```text
read_token=FileNotFoundError   # no token to read
kube_api=URLError              # egress to the kube API dropped
exfil=BLOCKED                  # egress to the sink dropped
# sink log: no new 'received' line
```

## Blast-radius report

| pod | runtime | sa_token | mcp-tools:8000 | kube-api:443 | sink:9000 |
|---|---|---|---|---|---|
| sandbox-runner (before) | runc | yes | REACH | REACH | REACH |
| sandbox-runner (after)  | gVisor | no | BLOCKED | BLOCKED | BLOCKED |
| rogue (before)          | runc | yes | REACH | REACH | REACH |
| rogue (after)           | runc | yes | BLOCKED | REACH | BLOCKED |

`REACH` = connected (or refused: host up, port closed). `BLOCKED` = timed out — a NetworkPolicy dropped the packets. The report doubles as an enforcement check: on a cluster where NetworkPolicy isn't enforced, `BLOCKED` never appears, and the fence is a false green.

## gVisor is the machine-dependent piece

k3s doesn't auto-detect `runsc`. [`gvisor/install-gvisor.sh`](gvisor/install-gvisor.sh) installs the binary and a containerd runtime handler into the k3d node and restarts k3s. It runs on the host (needs Docker), picks your arch, and uses gVisor's `systrap` platform (no `/dev/kvm` needed inside a Docker Desktop / Colima VM).

If it doesn't come up on your machine, the lab still runs: `fence` falls back to `runc` and says so, and the two load-bearing cuts — NetworkPolicy and the dropped token — are unaffected. gVisor changes the runtime column of the report, not whether the exfil is stopped.

## NetworkPolicy on k3d
k3s ships kube-router as its NetworkPolicy controller, so the policies here are enforced once applied (Flannel does the CNI, kube-router the policy). A cluster created with `--disable-network-policy`, or with a CNI whose policy engine is off, will not enforce them — and the blast-radius report will show it.

## Cleanup
```bash
./cleanup.sh            # internet ns, sandbox-runner, netpol, then Part 3
./cleanup.sh --cluster  # whole k3d cluster
```
