# Captured output

- `local/`: real output from the app code (SPIRE 1.15.3 server+agent with join_token + unix attestors, real X.509-SVIDs)
  run as local processes by `scripts/local-smoke.sh` with `LLM_MODE=mock`.
  No cluster, no mesh, so `peer=-` everywhere.
- `k3d/`: written by `task part2:capture` on a machine that can pull images.
  This is where the k8s_psat + k8s workload attestation output lives.
