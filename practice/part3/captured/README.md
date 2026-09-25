# Captured output

- `local/` — the Part 3 flow run as local processes: SPIRE 1.15.3 (join_token + unix
  workload attestor, one Unix user per workload), Keycloak 26.7.4 (dev mode, realm import),
  OPA 1.20.1, Redis, mock LLM. `driver.log` mirrors the `run.sh` steps from `login` to `bypass`.
  Differences from k3d: no Linkerd (so `peer=-`), and localhost URLs instead of Service DNS.
- `k3d/` — `task part3:capture` on the k3d cluster. The post quotes these files.
