#!/usr/bin/env bash
# Remove Part 6 (egress gateway, store credential, paved NetworkPolicies) and everything Part 5 installed.
# Pass --cluster to delete the whole k3d cluster.
source "$(dirname "$0")/../../scripts/lib.sh"
if [[ "${1:-}" == "--cluster" ]]; then
  k3d cluster delete "$CLUSTER"
else
  kubectl -n "$NS" delete deploy,svc,sa egress-gateway --ignore-not-found
  kubectl -n "$NS" delete configmap egress-policy --ignore-not-found
  kubectl -n "$NS" delete secret store-token --ignore-not-found
  "$(dirname "$0")/../part5/cleanup.sh"
fi
