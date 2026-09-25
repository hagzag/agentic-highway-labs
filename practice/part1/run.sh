#!/usr/bin/env bash
# Part 1 — The Safe Highway: bumpy road -> mTLS road -> authenticated agent still does damage.
#   ./run.sh            run every step
#   ./run.sh <step>     up | sniff | mesh | edges | inject | key | capture
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

up() {
  cluster_up
  image_build
  say "Deploying planner, executor, mcp-tools and redis (no mesh yet)"
  kubectl apply -f "$HERE/manifests/" >/dev/null
  llm_config
  kubectl -n "$NS" rollout restart deploy >/dev/null
  wait_ready
  kubectl -n "$NS" get pods -o wide
}

do_sniff() {
  say "Sniffing Redis (eth0) while the planner queues a plan"
  sniff eth0
}

mesh() {
  export PATH="$HOME/.linkerd2/bin:$PATH"
  if ! linkerd version --client --short 2>/dev/null | grep -q "$LINKERD2_VERSION"; then
    say "Installing linkerd CLI $LINKERD2_VERSION"
    curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install-edge | sh >/dev/null
  fi
  say "Installing Gateway API $GATEWAY_API_VERSION CRDs (Linkerd needs them)"
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
  if ! kubectl get ns linkerd >/dev/null 2>&1; then
    say "Installing Linkerd control plane"
    linkerd install --crds | kubectl apply -f - >/dev/null
    linkerd install | kubectl apply -f - >/dev/null
    linkerd check --wait 5m >/dev/null
    linkerd viz install | kubectl apply -f - >/dev/null
    linkerd viz check --wait 5m >/dev/null
  fi
  say "Paving the road: inject the proxy into every pod in '$NS'"
  kubectl annotate ns "$NS" linkerd.io/inject=enabled --overwrite >/dev/null
  # Servers first, clients second. A client whose long-lived Redis connection is
  # opened before the server is meshed/discoverable can keep a plaintext TCP stream.
  kubectl -n "$NS" rollout restart deploy/redis deploy/mcp-tools >/dev/null
  wait_ready
  kubectl -n "$NS" rollout restart deploy/planner-agent deploy/executor-agent >/dev/null
  wait_ready
  linkerd check --proxy --namespace "$NS" >/dev/null && echo "linkerd check --proxy: ok"
  kubectl -n "$NS" get pods
}

edges() {
  say "Who talks to whom, with which identity"
  plan "$RANDOM" >/dev/null; sleep 15   # generate traffic, let viz scrape
  linkerd viz edges deploy -n "$NS"
}

inject() {
  say "Poisoning the inventory, then running the planner"
  tools_admin reset >/dev/null
  tools_admin poison
  plan 42
  sleep 5
  say "mcp-tools log: every call authenticated, and the bucket is gone"
  applogs mcp-tools mcp-tools 60 | grep 'tool=' || true
}

key() {
  say "The borrowed static credential every agent pod carries"
  kubectl -n "$NS" exec deploy/executor-agent -c executor -- sh -c \
    'echo "LLM_API_KEY=${LLM_API_KEY:0:6}… (${#LLM_API_KEY} chars, mode=$LLM_MODE)"'
}

capture() {
  local out="$HERE/captured/k3d"; mkdir -p "$out"
  up                          2>&1 | tee "$out/00-up.txt"
  tools_admin reset >/dev/null
  do_sniff                    2>&1 | tee "$out/01-sniff-plaintext.txt"
  mesh                        2>&1 | tee "$out/02-mesh.txt"
  edges                       2>&1 | tee "$out/03-edges.txt"
  do_sniff                    2>&1 | tee "$out/04-sniff-mtls.txt"
  say "Inside the pod, after the proxy (lo)"; sniff lo 2>&1 | tee "$out/05-sniff-inside-pod.txt"
  inject                      2>&1 | tee "$out/06-inject.txt"
  key                         2>&1 | tee "$out/07-static-key.txt"
  applogs executor-agent executor > "$out/executor.log"
  applogs mcp-tools mcp-tools > "$out/mcp-tools.log"
  say "Captured to $out"
}

case "${1:-all}" in
  up) up ;; sniff) do_sniff ;; mesh) mesh ;; edges) edges ;; inject) inject ;; key) key ;;
  capture) capture ;;
  all) up; do_sniff; mesh; edges; do_sniff; inject; key ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
