#!/usr/bin/env bash
# Shared helpers and pinned versions for every part. Source, don't execute.
set -euo pipefail

# --- Versions (verified 2026-09-24) ------------------------------------------
export CLUSTER="${CLUSTER:-highway}"
export LINKERD2_VERSION="${LINKERD2_VERSION:-edge-26.9.3}"   # Linkerd OSS ships edge releases only
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}" # Linkerd 2.20 accepts 1.2.1-1.5.1
export SPIRE_VERSION="${SPIRE_VERSION:-1.15.3}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:latest}"
export IMAGE="highway-agent:dev"
export NS=migration

# --- LLM (Part 1-2 use a static key on purpose; see Part 3) ------------------
export LLM_MODE="${LLM_MODE:-mock}"                          # mock | live
export LLM_BASE_URL="${LLM_BASE_URL:-https://litellm.tikalk.dev}"
export LLM_MODEL="${LLM_MODEL:-gpt-4o-mini}"
export LLM_API_KEY="${LLM_API_KEY:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
need() { for b in "$@"; do command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }; done; }

cluster_up() {
  need docker k3d kubectl
  if ! k3d cluster list -o json | grep -q "\"name\":\"$CLUSTER\""; then
    say "Creating k3d cluster '$CLUSTER'"
    k3d cluster create "$CLUSTER" --agents 1 \
      --k3s-arg "--disable=traefik@server:0" --wait
  fi
  kubectl config use-context "k3d-$CLUSTER" >/dev/null
}

image_build() {
  say "Building $IMAGE and importing it into k3d"
  docker build -q -t "$IMAGE" "$REPO_ROOT/src"
  k3d image import "$IMAGE" -c "$CLUSTER" >/dev/null
}

llm_config() {
  kubectl -n "$NS" create secret generic llm-credentials \
    --from-literal=LLM_API_KEY="$LLM_API_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" patch configmap highway-config --type merge -p \
    "{\"data\":{\"LLM_MODE\":\"$LLM_MODE\",\"LLM_BASE_URL\":\"$LLM_BASE_URL\",\"LLM_MODEL\":\"$LLM_MODEL\"}}" >/dev/null
}

wait_ready() { kubectl -n "$NS" rollout status deploy --timeout=180s >/dev/null; }

tools_admin() {  # tools_admin reset|poison|state
  local method=POST; [[ "$1" == state ]] && method=GET
  kubectl -n "$NS" exec deploy/mcp-tools -c mcp-tools -- python -c \
    "import urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8000/admin/$1', method='$method')).read().decode())"
}

plan() {  # plan <task-id>
  kubectl -n "$NS" exec deploy/planner-agent -c planner -- \
    python -m highway.planner --task-id "${1:-42}" --requested-by "${REQUESTED_BY:-haggai}"
}

# Sniff Redis traffic from an ephemeral container in the redis pod.
# Port 4143: Redis is an opaque port in Linkerd, so meshed clients connect to the
# peer's inbound proxy on 4143 (opaque transport) instead of 6379.
#   sniff eth0 -> what the network sees      sniff lo -> what's inside the pod
sniff() {
  local iface="${1:-eth0}" pod c
  pod=$(kubectl -n "$NS" get pod -l app=redis -o jsonpath='{.items[0].metadata.name}')
  c="sniff-$(date +%s)"
  kubectl -n "$NS" debug "pod/$pod" -c "$c" --image="$NETSHOOT_IMAGE" --target=redis \
    --profile=netadmin -- timeout 20 tcpdump -i "$iface" -A -s0 -nn -l 'tcp port 6379 or tcp port 4143' >/dev/null
  kubectl -n "$NS" wait --for=jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$c\")].state.running}" \
    "pod/$pod" --timeout=90s >/dev/null 2>&1 || sleep 10
  sleep 2
  plan "$RANDOM" >/dev/null
  sleep 20
  local raw; raw=$(kubectl -n "$NS" logs "$pod" -c "$c" 2>/dev/null || true)
  echo "iface=$iface packets_with_payload=$(grep -ac 'length [1-9]' <<<"$raw" || true)" \
       "plaintext_instruction_hits=$(grep -ac '"instruction"' <<<"$raw" || true)"
  grep -a -o '"instruction": "[^"]*"' <<<"$raw" | sort -u | head -5 || true
  # Which flows carried plaintext? (src > dst, port 6379 = plain TCP, 4143 = Linkerd inbound)
  grep -a 'RESP' <<<"$raw" | awk '{print "plaintext flow:", $3, $4, $5}' | sort | uniq -c | head -5 || true
  if ! grep -aq '"instruction"' <<<"$raw"; then
    echo "--- no plaintext. First payload bytes (TLS records start 0x16/0x17 0x03 0x03):"
    grep -a -m3 'length [1-9]' <<<"$raw" || true
  fi
}
