#!/usr/bin/env bash
# Remove Part 4 (sink, sandbox-runner, NetworkPolicies) and everything Part 3 installed.
# Pass --cluster to delete the whole k3d cluster.
source "$(dirname "$0")/../../scripts/lib.sh"
if [[ "${1:-}" == "--cluster" ]]; then
  k3d cluster delete "$CLUSTER"
else
  kubectl delete ns internet --ignore-not-found
  kubectl -n "$NS" delete netpol mcp-tools-ingress runner-egress --ignore-not-found
  kubectl -n "$NS" delete deploy,svc,sa sandbox-runner --ignore-not-found
  kubectl delete runtimeclass gvisor --ignore-not-found
  "$(dirname "$0")/../part3/cleanup.sh"
fi
