#!/usr/bin/env bash
# Remove SPIRE and the Part 2 workloads. Pass --cluster to delete the whole k3d cluster.
source "$(dirname "$0")/../../scripts/lib.sh"
if [[ "${1:-}" == "--cluster" ]]; then
  k3d cluster delete "$CLUSTER"
else
  kubectl delete ns "$NS" spire --ignore-not-found
  kubectl delete clusterrole,clusterrolebinding spire-server spire-agent --ignore-not-found
fi
