#!/usr/bin/env bash
# Part 2 — License Plates: SPIRE workload identity + JWS-signed payloads across Redis.
#   ./run.sh            run every step
#   ./run.sh <step>     up | svid | forge-open | sign | forge | tamper | poison | capture
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
TD=highway.lab
SS() { kubectl -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
exec_in() { local d=$1; shift; kubectl -n "$NS" exec "deploy/$d" -c "${d%-agent}" -- "$@"; }

up() {
  say "Part 1 road first (cluster, agents, Linkerd)"
  "$HERE/../part1/run.sh" up
  "$HERE/../part1/run.sh" mesh

  say "Installing SPIRE $SPIRE_VERSION (server + agent DaemonSet)"
  for f in "$HERE"/manifests/0*.yaml "$HERE"/manifests/1*.yaml; do
    sed "s/SPIRE_VERSION/$SPIRE_VERSION/" "$f" | kubectl apply -f - >/dev/null
  done
  kubectl -n spire rollout status statefulset/spire-server --timeout=180s >/dev/null
  kubectl -n spire rollout status daemonset/spire-agent --timeout=180s >/dev/null

  say "Registering identities: node alias + one entry per agent"
  SS entry create -node -spiffeID "spiffe://$TD/k8s-node" -selector k8s_psat:cluster:highway >/dev/null || true
  for sa in planner-agent executor-agent mcp-tools; do
    SS entry create -parentID "spiffe://$TD/k8s-node" -spiffeID "spiffe://$TD/ns/$NS/sa/$sa" \
      -selector "k8s:ns:$NS" -selector "k8s:sa:$sa" >/dev/null || true
  done
  SS entry show -selector k8s:ns:$NS | grep -E 'SPIFFE ID|Selector'

  say "Redeploying agents with the Workload API socket (signing OFF)"
  kubectl apply -f "$HERE/manifests/20-agents-spiffe.yaml" >/dev/null
  wait_ready
}

svid() {
  say "Each agent asks the local SPIRE agent: who am I?"
  local py='from spiffe import WorkloadApiClient as W
try:
    s = W().fetch_x509_svid(); c = s.leaf
    print(s.spiffe_id, "| expires", c.not_valid_after_utc.isoformat(), "| issuer", c.issuer.rfc4514_string())
except Exception as e:
    print(type(e).__name__ + ":", str(e).split("response from the Workload API: ")[-1])'
  for d in planner-agent executor-agent; do printf '%-15s ' "$d"; exec_in "$d" python -c "$py"; done
  printf '%-15s ' rogue; kubectl -n "$NS" exec deploy/rogue -c rogue -- python -c "$py"
}

forge_open() {
  say "BREAK: signing is off. The rogue pod pushes a task straight into Redis"
  tools_admin reset >/dev/null
  kubectl -n "$NS" exec deploy/rogue -c rogue -- python -m highway.forge unsigned
  sleep 5
  kubectl -n "$NS" logs deploy/executor-agent -c executor --since=15s | grep -E 'executor=(task|tool_call)'
  kubectl -n "$NS" logs deploy/mcp-tools -c mcp-tools --since=15s | grep 'tool=delete_bucket'
}

sign() {
  say "FIX: planner signs with its X.509-SVID; executor verifies against the SPIRE bundle"
  kubectl -n "$NS" patch configmap highway-signing --type merge \
    -p '{"data":{"SIGN_PAYLOADS":"true","VERIFY_PAYLOADS":"true"}}' >/dev/null
  kubectl -n "$NS" rollout restart deploy/planner-agent deploy/executor-agent >/dev/null
  wait_ready
  tools_admin reset >/dev/null
  plan 43
  sleep 5
  kubectl -n "$NS" logs deploy/executor-agent -c executor --since=15s | grep -E 'executor='
}

forge() {
  say "Rogue tries again: unsigned, then a self-signed cert claiming the planner's SPIFFE ID"
  kubectl -n "$NS" exec deploy/rogue -c rogue -- python -m highway.forge unsigned
  kubectl -n "$NS" exec deploy/rogue -c rogue -- python -m highway.forge self-signed
  sleep 5
  kubectl -n "$NS" logs deploy/executor-agent -c executor --since=10s | grep REJECTED
}

tamper() {
  say "Rogue rewrites signed tasks while they sit in the queue (executor paused)"
  kubectl -n "$NS" scale deploy/executor-agent --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app=executor-agent --timeout=90s >/dev/null 2>&1 || true
  plan 44
  kubectl -n "$NS" exec deploy/rogue -c rogue -- python -m highway.forge tamper
  kubectl -n "$NS" scale deploy/executor-agent --replicas=1 >/dev/null
  wait_ready; sleep 8
  kubectl -n "$NS" logs deploy/executor-agent -c executor | grep -E 'REJECTED|executor=task'
}

poison() {
  say "BREAK AGAIN: poisoned inventory -> planner signs the bad step itself"
  tools_admin reset >/dev/null
  tools_admin poison >/dev/null
  plan 45
  sleep 6
  kubectl -n "$NS" logs deploy/executor-agent -c executor --since=15s | grep -E 'executor=(task|tool_call)'
  kubectl -n "$NS" logs deploy/mcp-tools -c mcp-tools --since=15s | grep 'tool=delete_bucket'
  say "Valid signature. Right identity. Wrong decision. Identity is not permission (Part 3)."
}

capture() {
  local out="$HERE/captured/k3d"; mkdir -p "$out"
  up          2>&1 | tee "$out/00-up.txt"
  svid        2>&1 | tee "$out/01-svid.txt"
  forge_open  2>&1 | tee "$out/02-forge-open.txt"
  sign        2>&1 | tee "$out/03-sign.txt"
  forge       2>&1 | tee "$out/04-forge.txt"
  tamper      2>&1 | tee "$out/05-tamper.txt"
  poison      2>&1 | tee "$out/06-poison.txt"
  kubectl -n spire logs daemonset/spire-agent --tail=200 | grep -iE 'attest|svid' | tail -20 > "$out/spire-agent.log" || true
  say "Captured to $out"
}

case "${1:-all}" in
  up) up ;; svid) svid ;; forge-open) forge_open ;; sign) sign ;; forge) forge ;;
  tamper) tamper ;; poison) poison ;; capture) capture ;;
  all) up; svid; forge_open; sign; forge; tamper; poison ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
