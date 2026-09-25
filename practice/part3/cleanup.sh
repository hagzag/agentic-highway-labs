#!/usr/bin/env bash
# Remove Part 3 (Keycloak, STS, gateways) plus everything Part 2 installed.
# Pass --cluster to delete the whole k3d cluster.
source "$(dirname "$0")/../../scripts/lib.sh"
if [[ "${1:-}" == "--cluster" ]]; then
  k3d cluster delete "$CLUSTER"
else
  kubectl delete ns idp --ignore-not-found
  "$(dirname "$0")/../part2/cleanup.sh"
fi
