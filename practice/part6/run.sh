#!/usr/bin/env bash
# Part 6 — The Paved Track: the sandbox holds no credential; an egress gateway adds it.
#   ./run.sh            run every step
#   ./run.sh <step>     up | paved | break | permits | replay | capture | doctor
# This is the default CNCF's new agent runtimes ship (Agent Substrate's egress gateway,
# OpenShell's providers). It ends Part 4's theft. Then the break: a poisoned script
# doesn't steal the store credential, it asks the gateway to spend it. The fix puts
# Part 3's permit check and Part 5's black box at the gateway, before the credential goes on.
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
P4="$HERE/../part4/run.sh"
P5="$HERE/../part5/run.sh"
OUT="$HERE/captured/k3d"
TD=highway.lab
SS() { kubectl -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
planner() { kubectl -n "$NS" exec deploy/planner-agent -c planner -- "$@"; }
audit_cli() { kubectl -n "$NS" exec -i deploy/audit -c audit -- python -m highway.audit "$@"; }
show() { applogs "$1" "$2" "$3" | grep -E "$4" || true; }
state() { tools_admin state | python3 -c 'import json,sys; print("buckets:", [b["name"] for b in json.load(sys.stdin)["buckets"]])'; }

plan_as() {  # plan_as <task-id> <user>
  local tok; tok=$(planner python -m highway.login --user "$2")
  planner python -m highway.planner --task-id "$1" --user-token "$tok"
}

cleanup_run() {  # cleanup_run <task-id>: poisoned "cleanup" note -> run_script -> egress gateway
  tools_admin reset >/dev/null
  tools_admin poison-cleanup >/dev/null
  queue_flush
  plan_as "$1" tester >/dev/null
  sleep 10
}

# Same recorder wiring as Part 5, plus the egress gateway. Strategic merge by name.
SPIRE_VOL='{"name":"spire","hostPath":{"path":"/run/spire/agent-sockets","type":"Directory"}}'
SPIRE_MNT='{"name":"spire","mountPath":"/run/spire/sockets","readOnly":true}'
audit_env() {  # audit_env <deploy> <container> [extra env objects...]
  local d=$1 c=$2 env='{"name":"AUDIT_URL","value":"http://audit:8080"}'
  shift 2
  for e in "$@"; do env+=",$e"; done
  kubectl -n "$NS" patch deploy "$d" --type strategic -p \
    "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[$SPIRE_VOL],\"containers\":[{\"name\":\"$c\",\"env\":[$env],\"volumeMounts\":[$SPIRE_MNT]}]}}}}" >/dev/null
}
REQ='{"name":"AUDIT_REQUIRED","value":"true"}'
recorder_on() {
  for p in sts:sts planner-agent:planner executor-agent:executor mcp-tools:mcp-tools; do
    audit_env "${p%:*}" "${p#*:}"
  done
  audit_env mcp-gateway gateway "$REQ" '{"name":"FORWARD_PERMIT","value":"true"}'
  audit_env egress-gateway egress-gateway "$REQ"
  audit_env sandbox-runner sandbox-runner '{"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}' \
    '{"name":"EGRESS_URL","value":"http://egress-gateway:8080"}'
}

up() {
  say "Parts 1-5 first: the road, plates, permits, the fence and the black box"
  "$P5" up

  say "The store gets a credentialed REST API (the kind of upstream a sandbox egress gateway serves)"
  kubectl -n "$NS" create secret generic store-token --from-literal=token="store-$(openssl rand -hex 12)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" patch deploy mcp-tools --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"mcp-tools","env":[{"name":"STORE_TOKEN","valueFrom":{"secretKeyRef":{"name":"store-token","key":"token"}}}]}]}}}}' >/dev/null

  say "The egress gateway: holds the store credential, OPA sidecar for the permit check"
  SS entry create -parentID "spiffe://$TD/k8s-node" -spiffeID "spiffe://$TD/ns/$NS/sa/egress-gateway" \
    -selector "k8s:ns:$NS" -selector "k8s:sa:egress-gateway" >/dev/null 2>&1 || true
  kubectl -n "$NS" create configmap egress-policy \
    --from-file="$HERE/policy/egress.rego" --from-file="$HERE/policy/data.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sed "s/OPA_VERSION/$OPA_VERSION/" "$HERE/manifests/10-egress-gateway.yaml" | kubectl apply -f - >/dev/null

  say "Pave the track: Part 4's fenced runner (no token, gVisor if present), egress only via the gateway"
  "$P4" fence >/dev/null
  kubectl apply -f "$HERE/manifests/20-paved.yaml" >/dev/null
  recorder_on
  wait_ready
  kubectl -n "$NS" get pods -l 'app in (egress-gateway,sandbox-runner,mcp-tools)'
}

paved() {
  say "PAVED 1: Part 4's exfil again. No token in the sandbox, no route to the sink"
  tools_admin reset >/dev/null; tools_admin poison-exfil >/dev/null; queue_flush
  plan_as 80 tester >/dev/null; sleep 8
  show sandbox-runner sandbox-runner 30 "runner=done"
  say "PAVED 2: the store credential isn't in the sandbox either, and the store refuses a call without it"
  kubectl -n "$NS" exec deploy/sandbox-runner -c sandbox-runner -- python -c \
    'import os,urllib.request as u
print("env STORE_TOKEN:", "STORE_TOKEN" in os.environ)
try: u.urlopen(u.Request("http://mcp-tools:8000/store/v1/buckets/prod-archive", method="DELETE"), timeout=3)
except Exception as e: print("direct DELETE:", type(e).__name__, getattr(e, "code", ""))' || true
}

break_it() {
  say "BREAK: EGRESS_PERMITS=false (the sandbox default). A poisoned note says 'run the cleanup script'"
  state
  cleanup_run 81
  show sandbox-runner sandbox-runner 30 "runner=done"
  say "The gateway spent the credential for a script it knows nothing about"
  show egress-gateway egress-gateway 30 'egress='
  show mcp-tools mcp-tools 30 'store='
  state
}

permits() {
  say "FIX: EGRESS_PERMITS=true. The gateway asks on whose behalf, and records it, before the credential goes on"
  kubectl -n "$NS" set env deploy/egress-gateway -c egress-gateway EGRESS_PERMITS=true >/dev/null
  kubectl -n "$NS" rollout status deploy/egress-gateway --timeout=120s >/dev/null
  wait_ready
  cleanup_run 82
  show sandbox-runner sandbox-runner 30 "runner=done"
  show egress-gateway egress-gateway 30 'egress='
  state
}

replay() {
  say "Replay from the bucket: the black box names who spent the credential (task 81) and who couldn't (task 82)"
  audit_cli replay --bucket prod-archive
  audit_cli replay --task-id 82 | grep -E 'egress' || true
}

doctor() {
  say "Pods"; kubectl -n "$NS" get pods -o wide
  say "NetworkPolicies"; kubectl -n "$NS" get netpol
  say "Egress gateway env"; kubectl -n "$NS" get deploy egress-gateway -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
  say "Recent egress decisions"; applogs egress-gateway egress-gateway 600 | tail -10
}

capture() {
  mkdir -p "$OUT"
  up       2>&1 | tee "$OUT/00-up.txt"
  paved    2>&1 | tee "$OUT/01-paved.txt"
  break_it 2>&1 | tee "$OUT/02-break.txt"
  permits  2>&1 | tee "$OUT/03-permits.txt"
  replay   2>&1 | tee "$OUT/04-replay.txt"
  applogs egress-gateway egress-gateway > "$OUT/egress-gateway.log"
  applogs mcp-tools mcp-tools > "$OUT/mcp-tools.log"
  say "Captured to $OUT"
}

case "${1:-all}" in
  up) up ;; paved) paved ;; break) break_it ;; permits) permits ;; replay) replay ;;
  doctor) doctor ;; capture) capture ;;
  all) up; paved; break_it; permits; replay ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
