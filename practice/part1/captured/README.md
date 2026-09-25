# Captured output

- `local/`: real output from the app code (planner, executor, MCP tools, Redis sniff)
  run as local processes by `scripts/local-smoke.sh` with `LLM_MODE=mock`.
  No cluster, no mesh, so `peer=-` everywhere.
- `k3d/`: written by `task part1:capture` on a machine that can pull images.
  This is where the Linkerd output lives (`edges`, `peer=` identities, TLS sniff).
