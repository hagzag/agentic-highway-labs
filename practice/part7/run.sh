#!/usr/bin/env bash
# Part 7 — Agent Substrate: the paved track, for real.
#   ./run.sh            run every step
#   ./run.sh <step>     up | paved | break | fix | capture | doctor | down
#   macOS only:         vm-shell | vm-down  (every other step runs inside a Lima VM)
# Runs Part 6's break against Agent Substrate (CNCF Sandbox): the runner becomes a
# Substrate actor (gVisor), the store credential lives in Substrate's credential
# provider, and Substrate's egress gateway injects it. Then the fix: Substrate injects
# the actor's JWT instead, and store-gate (Part 6's gateway) checks the permit.
#
# NOT YET RUN END TO END (written 2026-11-21 from Substrate's docs). Needs Linux:
# Substrate requires gVisor or a microVM, so on macOS this script creates a Lima Linux VM
# (lima.yaml) and re-runs itself there via vm-exec.sh.
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/captured/kind"
SUBSTRATE_DIR="${SUBSTRATE_DIR:-$REPO_ROOT/.cache/substrate}"
ATESPACE=highway
ACTOR=runner-1
ROUTER_PORT="${ROUTER_PORT:-18000}"
VM="${PART7_VM:-highway-substrate}"

# --- macOS: Substrate needs gVisor or a microVM, so run every step inside a Lima Linux VM
vm_ensure() {
  if ! command -v limactl >/dev/null; then
    command -v brew >/dev/null || { echo "missing: limactl (install Homebrew, then: brew install lima)"; exit 1; }
    say "Installing Lima"; brew install lima
  fi
  case "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null || true)" in
    Running) ;;
    Stopped) say "Starting Lima VM $VM"; limactl start "$VM" ;;
    *) say "Creating Lima VM $VM (Ubuntu 24.04, 4 CPU, 8 GiB). First boot installs Docker, kind, kubectl, Go: ~5-10 min"
       sed "s|@REPO_ROOT@|$REPO_ROOT|g" "$HERE/lima.yaml" > "$HERE/.lima.yaml"
       limactl start --tty=false --name="$VM" "$HERE/.lima.yaml" ;;
  esac
}
if [[ "$(uname -s)" == Darwin && -z "${PART7_IN_VM:-}" ]]; then
  case "${1:-all}" in
    vm-down)  limactl delete -f "$VM" ;;
    vm-shell) vm_ensure; limactl shell --workdir "$REPO_ROOT" "$VM" ;;
    *) vm_ensure; say "Running Part 7 '${1:-all}' inside Lima VM $VM"
       limactl shell --workdir "$REPO_ROOT" "$VM" ./practice/part7/vm-exec.sh "${1:-all}" ;;
  esac
  exit
fi

ate() { kubectl ate "$@"; }
k() { kubectl -n "$NS" "$@"; }
py_in() { k exec "deploy/$1" -c "$1" -- python -c "$2"; }
state() { py_in mcp-tools "import urllib.request as u; import json; print('buckets:', [b['name'] for b in json.loads(u.urlopen('http://127.0.0.1:8000/admin/state').read())['buckets']])"; }
reset() { py_in mcp-tools "import urllib.request as u; u.urlopen(u.Request('http://127.0.0.1:8000/admin/reset', method='POST'))"; }
permit() {  # permit <scopes> [sub] -> a permit from the lab STS stand-in
  py_in sts "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8080/mint?scope=${1// /+}&sub=${2:-tester}').read().decode())"
}
router() {  # keep a port-forward to Substrate's router open for this script
  if ! curl -s -o /dev/null "localhost:$ROUTER_PORT" 2>/dev/null; then
    kubectl -n ate-system port-forward svc/atenet-router "$ROUTER_PORT:80" >/dev/null 2>&1 &
    sleep 3
  fi
}
call() {  # call <script> [permit]: run_script on the actor, through the router
  router
  PYTHONPATH="$REPO_ROOT/src" python3 "$HERE/call.py" "http://localhost:$ROUTER_PORT" "$ATESPACE/$ACTOR" "$HERE/scripts/$1" "${2:-}"
}
egress_policy() {  # egress_policy <file|none>: replace the actor's EgressPolicy
  ate delete egress-policy "$ACTOR" -a "$ATESPACE" >/dev/null 2>&1 || true
  [[ "$1" == none ]] || ate create egress-policy "$ACTOR" -a "$ATESPACE" -f "$HERE/manifests/$1"
}
actor_jwks() {  # Substrate's IdP (cmd/ate-idp-server) serves OIDC discovery + keys; find its Service
  local svc port
  svc=$(kubectl -n ate-system get svc -o name | grep -m1 idp | cut -d/ -f2 || true)
  port=$(kubectl -n ate-system get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
  echo "${ACTOR_JWKS_URL:-http://$svc.ate-system.svc.cluster.local:$port/.well-known/jwks.json}"
}

up() {
  need git go kind kubectl docker python3

  say "Agent Substrate $SUBSTRATE_REF on kind (Substrate's own dev path)"
  [[ -d "$SUBSTRATE_DIR/.git" ]] || git clone -q https://github.com/agent-substrate/substrate "$SUBSTRATE_DIR"
  git -C "$SUBSTRATE_DIR" fetch -q origin "$SUBSTRATE_REF" && git -C "$SUBSTRATE_DIR" checkout -q FETCH_HEAD
  ( cd "$SUBSTRATE_DIR" || exit 1
    hack/create-kind-cluster.sh
    ATE_INSTALL_KIND=true go run ./cmd/ate-setup deploy ate-system \
      --credential-provider='{"name":"k8s.io"}' \
      --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
    go install ./cmd/kubectl-ate )

  say "The highway image, the store, the lab STS and store-gate"
  docker build -q -t "$IMAGE" "$REPO_ROOT/src"
  kind load docker-image "$IMAGE" --name "$(kind get clusters | head -1)"
  kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  k create secret generic store-token --from-literal=token="store-$(openssl rand -hex 12)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  python3 - "$REPO_ROOT/practice/part6/policy/data.json" "actor/$ATESPACE/$ACTOR" > "$HERE/.data.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["lab"]["egress_callers"] = [sys.argv[2]]; print(json.dumps(d))
EOF
  k create configmap egress-policy --from-file="$REPO_ROOT/practice/part6/policy/egress.rego" \
    --from-file=data.json="$HERE/.data.json" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sed -e "s|IMAGE|$IMAGE|" -e "s|OPA_VERSION|$OPA_VERSION|" -e "s|\"ACTOR_JWKS_URL\"|\"$(actor_jwks)\"|" \
    "$HERE/manifests/10-highway.yaml" | kubectl apply -f - >/dev/null
  k rollout status deploy --timeout=180s >/dev/null

  say "Grant the highway atespace the store-token Secret (provider default-deny; read at startup)"
  kubectl -n ate-system patch configmap k8s-credential-provider-namespace-policy --type merge -p \
    "{\"data\":{\"namespace-policy.yaml\":\"policies:\\n- atespace: $ATESPACE\\n  allowedNamespaces:\\n  - $NS\\n\"}}"
  kubectl -n ate-system rollout restart deployment/k8s-credential-provider >/dev/null
  kubectl -n ate-system rollout status deployment/k8s-credential-provider --timeout=120s >/dev/null

  say "The runner as an actor: atespace, worker pool (gVisor), template, actor"
  ate create atespace "$ATESPACE" 2>/dev/null || true
  kubectl create ns "$ATESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$HERE/manifests/workerpool.yaml" >/dev/null
  sed "s|IMAGE|$IMAGE|" "$HERE/manifests/actor-template.yaml" > "$HERE/.actor-template.yaml"
  ate create actor-template -f "$HERE/.actor-template.yaml" 2>/dev/null || true
  ate create actor "$ACTOR" -a "$ATESPACE" --template sandbox-runner 2>/dev/null || true
  ate get actor "$ACTOR" -a "$ATESPACE"
}

paved() {
  say "PAVED: no EgressPolicy yet. Part 4's exfil from inside a gVisor actor"
  egress_policy none
  call exfil.py
}

break_it() {
  say "BREAK: grant the store credential (replaceHeaders + credentialUri). The poisoned cleanup script runs"
  reset; state
  egress_policy egress-break.yaml
  call cleanup-direct.py
  state
  echo "The actor never held the token; Substrate's egress gateway added it. Nothing asked on whose behalf."
}

fix() {
  say "FIX: the actor may reach only store-gate; Substrate injects the actor's JWT, not the store token"
  reset
  egress_policy egress-fix.yaml
  say "tester's permit (no buckets:delete)"
  call cleanup-gate.py "$(permit 'buckets:read buckets:copy scripts:run')"
  say "ops-admin's permit (holds buckets:delete): the retention lock still holds"
  call cleanup-gate.py "$(permit 'buckets:read buckets:delete scripts:run' ops-admin)"
  say "no permit"
  call cleanup-gate.py
  state
  say "store-gate's decisions (caller = the actor identity Substrate vouched for)"
  k logs deploy/store-gate -c store-gate --tail=20 | grep -E 'egress=' || true
}

doctor() {
  kubectl -n ate-system get pods
  ate get actor "$ACTOR" -a "$ATESPACE" || true
  ate get egress-policy "$ACTOR" -a "$ATESPACE" -o yaml || true
  k get pods
  kubectl -n ate-system logs deployment/atenet-egress --all-containers --tail=30 2>/dev/null | grep -iE 'denied|credential' || true
}

capture() {
  mkdir -p "$OUT"
  up       2>&1 | tee "$OUT/00-up.txt"
  paved    2>&1 | tee "$OUT/01-paved.txt"
  break_it 2>&1 | tee "$OUT/02-break.txt"
  fix      2>&1 | tee "$OUT/03-fix.txt"
  k logs deploy/store-gate -c store-gate > "$OUT/store-gate.log"
  say "Captured to $OUT"
}

down() { kind delete cluster --name "$(kind get clusters | head -1)"; }

case "${1:-all}" in
  up) up ;; paved) paved ;; break) break_it ;; fix) fix ;; doctor) doctor ;; capture) capture ;; down) down ;;
  all) up; paved; break_it; fix ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
