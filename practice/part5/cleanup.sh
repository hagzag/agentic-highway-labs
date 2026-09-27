#!/usr/bin/env bash
# Remove Part 5 (the audit collector, its tape and checkpoints) and everything Part 4 installed.
# Pass --cluster to delete the whole k3d cluster.
source "$(dirname "$0")/../../scripts/lib.sh"
if [[ "${1:-}" == "--cluster" ]]; then
  k3d cluster delete "$CLUSTER"
else
  kubectl -n "$NS" delete deploy,svc,sa audit --ignore-not-found
  kubectl -n "$NS" delete pvc audit-log --ignore-not-found           # the tape
  kubectl -n "$NS" delete configmap audit-checkpoints --ignore-not-found
  kubectl -n "$NS" delete role,rolebinding audit-checkpoint-writer --ignore-not-found
  "$(dirname "$0")/../part4/cleanup.sh"
fi
