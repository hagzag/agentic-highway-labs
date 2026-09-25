#!/usr/bin/env bash
# Part 3 — Driving Permits: delegation (sub + act), scopes, TTL, policy at the MCP gateway,
# and the LLM key moved behind a gateway the agents reach with their SVID.
#   ./run.sh            run every step
#   ./run.sh <step>     up | key | llm-gw | login | permit | poison | admin | steal | bypass | capture | doctor
#   LAB_USER=hagzag ./run.sh permit     # log in as someone else (hagzag, tester, ops-admin)
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
TD=highway.lab
SS() { kubectl -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
render() { sed -e "s/KEYCLOAK_VERSION/$KEYCLOAK_VERSION/" -e "s/OPA_VERSION/$OPA_VERSION/" "$1"; }
planner() { kubectl -n "$NS" exec deploy/planner-agent -c planner -- "$@"; }
rogue() { kubectl -n "$NS" exec deploy/rogue -c rogue -- "$@"; }

# The human's CLI. Stand-in: it runs inside the planner pod because that's where
# the cluster DNS is. A real CLI runs on a laptop and uses the device flow.
login_token() { planner python -m highway.login --user "${1:-$LAB_USER}"; }

plan3() {  # plan3 <task-id> [user]
  local tok; tok=$(login_token "${2:-$LAB_USER}")
  planner python -m highway.planner --task-id "$1" --user-token "$tok"
}

wait_svid() {  # wait_svid deploy:container ...
  local py='from spiffe import WorkloadApiClient as W; W().fetch_jwt_svid(audience={"probe"})'
  for pair in "$@"; do
    for i in $(seq 30); do
      kubectl -n "$NS" exec "deploy/${pair%:*}" -c "${pair#*:}" -- python -c "$py" >/dev/null 2>&1 \
        && { echo "${pair%:*}: SVID issued"; break; }
      [[ $i == 30 ]] && { echo "${pair%:*}: no SVID after 60s, run: ./run.sh doctor"; return 1; }
      sleep 2
    done
  done
}

show() {  # show <app> <container> <since-seconds> <grep-regex>
  applogs "$1" "$2" "$3" | grep -E "$4" || true
}

up() {
  say "Part 2 road first (cluster, Linkerd, SPIRE, signed tasks)"
  "$HERE/../part2/run.sh" up
  kubectl -n "$NS" patch configmap highway-signing --type merge \
    -p '{"data":{"SIGN_PAYLOADS":"true","VERIFY_PAYLOADS":"true"}}' >/dev/null

  say "Keycloak $KEYCLOAK_VERSION: the humans' identity provider (realm highway)"
  render "$HERE/manifests/00-idp.yaml" | kubectl apply -f - >/dev/null  # the pod waits for the realm below
  kubectl -n idp create configmap keycloak-realm --from-file="$HERE/idp/highway-realm.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  say "STS, MCP gateway (+ OPA $OPA_VERSION) and LLM gateway"
  kubectl -n "$NS" create configmap opa-policy \
    --from-file="$HERE/policy/mcp.rego" --from-file="$HERE/policy/data.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  for f in 10-sts 20-mcp-gateway 30-llm-gateway; do
    render "$HERE/manifests/$f.yaml" | kubectl apply -f - >/dev/null
  done
  for sa in sts mcp-gateway llm-gateway; do
    SS entry create -parentID "spiffe://$TD/k8s-node" -spiffeID "spiffe://$TD/ns/$NS/sa/$sa" \
      -selector "k8s:ns:$NS" -selector "k8s:sa:$sa" >/dev/null 2>&1 || true
  done
  SS entry show -selector "k8s:ns:$NS" | grep -E 'SPIFFE ID' | sort

  say "mcp-tools logs sub= from now on; agents restart with signing ON"
  kubectl -n "$NS" set env deploy/mcp-tools LOG_SUB=true >/dev/null
  kubectl -n "$NS" rollout restart deploy/planner-agent deploy/executor-agent >/dev/null
  wait_ready
  kubectl -n idp rollout status deploy/keycloak --timeout=300s >/dev/null
  wait_svid sts:sts mcp-gateway:gateway llm-gateway:llm-gateway
  kubectl -n "$NS" get pods; kubectl -n idp get pods
}

key() {
  say "BREAK: every agent pod carries the borrowed LLM key"
  kubectl -n "$NS" get deploy -o \
    jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].envFrom[*].secretRef.name}{"\n"}{end}'
  for d in planner-agent:planner executor-agent:executor; do
    printf '%-15s ' "${d%:*}"
    kubectl -n "$NS" exec "deploy/${d%:*}" -c "${d#*:}" -- bash -c \
      'echo "LLM_API_KEY=${LLM_API_KEY:0:6}… (${#LLM_API_KEY} chars) -> $LLM_BASE_URL"'
  done
  echo "Anyone who can exec into either pod, or read its env, walks away with it."
}

llm_gw() {
  say "FIX: agents lose the key; they reach the model through llm-gateway with a JWT-SVID"
  kubectl apply -f "$HERE/manifests/40-agents-permits.yaml" >/dev/null
  wait_ready
  wait_svid planner-agent:planner executor-agent:executor
  kubectl -n "$NS" get deploy -o \
    jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].envFrom[*].secretRef.name}{"\n"}{end}'
  kubectl -n "$NS" exec deploy/executor-agent -c executor -- bash -c \
    'echo "executor-agent  LLM_API_KEY=${LLM_API_KEY:-<unset>}  LLM_AUTH=$LLM_AUTH -> $LLM_BASE_URL"'
  tools_admin reset >/dev/null
  queue_flush
  plan 46 >/dev/null
  sleep 5
  say "Rogue (no SVID) calls the LLM gateway"
  rogue python -c "
import urllib.request as u, urllib.error as e
try: u.urlopen(u.Request('http://llm-gateway:8080/v1/chat/completions', data=b'{\"messages\":[]}', headers={'content-type':'application/json'}))
except e.HTTPError as x: print('rogue:', x.code, x.read().decode())"
  show llm-gateway llm-gateway 30 'llm='
}

login() {
  say "A human logs in: $LAB_USER @ Keycloak realm highway (password grant, lab only)"
  planner python -m highway.login --user "$LAB_USER" --claims
}

permit() {
  say "FIX: delegation ON. Planner and executor swap tokens at the STS; the gateway checks every call"
  kubectl -n "$NS" patch configmap highway-permits --type merge \
    -p '{"data":{"PERMITS":"true","MCP_URL":"http://mcp-gateway:8080/mcp"}}' >/dev/null
  kubectl -n "$NS" rollout restart deploy/planner-agent deploy/executor-agent >/dev/null
  wait_ready
  wait_svid planner-agent:planner executor-agent:executor >/dev/null
  tools_admin reset >/dev/null
  queue_flush
  plan3 46
  sleep 6
  say "STS: what each hop was given (and what was dropped)"
  show sts sts 20 'sts='
  say "MCP gateway: every tool call, with sub, act and the proven caller"
  show mcp-gateway gateway 20 'gateway='
  say "mcp-tools: the calls arrive from the gateway, on behalf of $LAB_USER"
  show mcp-tools mcp-tools 20 'tool='
  say "Inside the planner's permit (decoded)"
  planner python -c "
import json
from highway import login, permits
_, c = permits.exchange(login.login('$LAB_USER', '$LAB_USER'), scope='buckets:read buckets:copy buckets:delete', task_id='46')
print(json.dumps(c, indent=2))"
}

poison() {
  say "The Part 2 ending, replayed: poisoned inventory, validly signed delete"
  tools_admin reset >/dev/null
  tools_admin poison >/dev/null
  plan3 47
  sleep 6
  show sts sts 15 'sts=issued.*act=planner-agent '
  show executor-agent executor 15 'executor=(task|denied)'
  show mcp-gateway gateway 15 'gateway=DENY'
  show mcp-tools mcp-tools 15 'tool=delete_bucket'
  if tools_admin state | grep -q '"prod-archive"'; then echo "prod-archive: still there"; else echo "prod-archive: GONE"; fi
}

admin() {
  say "Same poison, but the human is ops-admin (holds buckets:delete)"
  tools_admin reset >/dev/null
  tools_admin poison >/dev/null
  plan3 48 ops-admin
  sleep 6
  show sts sts 15 'sts=issued.*act=planner-agent '
  show mcp-gateway gateway 15 'gateway=DENY'
  echo "Scope is necessary, not sufficient: some resources no permit can touch."
}

steal() {
  say "Rogue lifts a permit from the queue and presents it at the gateway (executor paused)"
  kubectl -n "$NS" scale deploy/executor-agent --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app=executor-agent --timeout=90s >/dev/null 2>&1 || true
  tools_admin reset >/dev/null
  queue_flush
  plan3 49 >/dev/null
  rogue python -m highway.forge steal
  sleep 2
  show mcp-gateway gateway 15 'gateway=DENY'
  queue_flush
  kubectl -n "$NS" scale deploy/executor-agent --replicas=1 >/dev/null
  wait_ready
}

bypass() {
  say "BREAK AGAIN: the rogue skips the gate and calls mcp-tools directly"
  tools_admin reset >/dev/null
  rogue python -m highway.forge bypass
  sleep 2
  show mcp-tools mcp-tools 15 'tool=delete_bucket'
  say "The permit is checked at the gate. Nothing forces traffic through the gate (Part 4)."
}

doctor() {
  say "Pods"
  kubectl -n "$NS" get pods -o wide; kubectl -n idp get pods -o wide
  say "SPIRE entries"
  SS entry show -selector "k8s:ns:$NS" | grep -E 'SPIFFE ID' | sort
  say "Keycloak: can $LAB_USER log in?"
  planner python -m highway.login --user "$LAB_USER" --claims | head -5 || true
  say "OPA: policy loaded? (should list highway.mcp)"
  kubectl -n "$NS" exec deploy/mcp-gateway -c gateway -- python -c \
    "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8181/v1/policies').read().decode()[:200])"
  say "Recent STS / gateway errors"
  applogs sts sts 600 | grep -E 'DENY|Error' | tail -5 || true
  applogs mcp-gateway gateway 600 | grep -E 'Error|Traceback' | tail -5 || true
}

capture() {
  local out="$HERE/captured/k3d"; mkdir -p "$out"
  up          2>&1 | tee "$out/00-up.txt"
  key         2>&1 | tee "$out/01-key.txt"
  llm_gw      2>&1 | tee "$out/02-llm-gw.txt"
  login       2>&1 | tee "$out/03-login.txt"
  permit      2>&1 | tee "$out/04-permit.txt"
  poison      2>&1 | tee "$out/05-poison.txt"
  admin       2>&1 | tee "$out/06-admin.txt"
  steal       2>&1 | tee "$out/07-steal.txt"
  bypass      2>&1 | tee "$out/08-bypass.txt"
  applogs sts sts > "$out/sts.log"
  applogs mcp-gateway gateway > "$out/mcp-gateway.log"
  applogs llm-gateway llm-gateway > "$out/llm-gateway.log"
  applogs executor-agent executor > "$out/executor.log"
  applogs mcp-tools mcp-tools > "$out/mcp-tools.log"
  say "Captured to $out"
}

case "${1:-all}" in
  up) up ;; key) key ;; llm-gw) llm_gw ;; login) login ;; permit) permit ;; poison) poison ;;
  admin) admin ;; steal) steal ;; bypass) bypass ;; capture) capture ;; doctor) doctor ;;
  all) up; key; llm_gw; login; permit; poison; admin; steal; bypass ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
