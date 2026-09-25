#!/usr/bin/env bash
# Remove the Part 1 workloads. Pass --cluster to delete the whole k3d cluster.
source "$(dirname "$0")/../../scripts/lib.sh"
if [[ "${1:-}" == "--cluster" ]]; then
  k3d cluster delete "$CLUSTER"
else
  kubectl delete ns "$NS" --ignore-not-found
fi
