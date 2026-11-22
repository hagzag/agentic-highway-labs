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
       limactl shell --workdir "$REPO_ROOT" "$VM" env PART7_TRACE="${PART7_TRACE:-}" PART7_REINSTALL="${PART7_REINSTALL:-}" bash ./practice/part7/vm-exec.sh "${1:-all}" ;;
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
router() {  # keep `kubectl ate proxy` open: localhost:$ROUTER_PORT -> the actor's port 80, via Substrate's router
  # The router requires a client certificate, so a plain port-forward can't talk to it; the ate proxy mints one.
  # One fresh proxy per script run: a proxy left from an earlier run keeps a stale view of the
  # router pods (and an expired client cert) and resets every connection.
  [[ -n "${PROXY_STARTED:-}" ]] && return
  pkill -f "port-forward svc/atenet-router" 2>/dev/null || true
  pkill -f "ate proxy actor" 2>/dev/null || true
  kubectl -n ate-system rollout status deploy/atenet-router --timeout=120s >/dev/null
  kubectl ate proxy actor "$ACTOR" "$ROUTER_PORT:80" -a "$ATESPACE" >"$HERE/.proxy.log" 2>&1 &
  for _ in $(seq 30); do (exec 3<>/dev/tcp/127.0.0.1/"$ROUTER_PORT") 2>/dev/null && { PROXY_STARTED=1; return; }; sleep 1; done
  echo "kubectl ate proxy did not come up:" >&2; cat "$HERE/.proxy.log" >&2; exit 1
}
call() {  # call <script> [permit]: run_script on the actor, through the router
  router
  # The highway image already has the MCP client; no pip install on the host
  docker run --rm --network host -v "$HERE:/part7:ro" "$IMAGE" \
    python /part7/call.py "http://localhost:$ROUTER_PORT" "$ATESPACE/$ACTOR" "/part7/scripts/$1" "${2:-}"
}
egress_policy() {  # egress_policy <file|none>: replace the actor's EgressPolicy
  ate delete egress-policy "$ACTOR" -a "$ATESPACE" >/dev/null 2>&1 || true
  [[ "$1" == none ]] || ate create egress-policy "$ACTOR" -a "$ATESPACE" -f "$HERE/manifests/$1"
}
actor_jwks() {  # Substrate's IdP (cmd/ate-idp-server): Service "idp" (443/TLS), JWKS at /openid/v1/jwks
  echo "${ACTOR_JWKS_URL:-https://idp.ate-system.svc/openid/v1/jwks}"
}
idp_ca() {  # the IdP's serving cert comes from the servicedns.podcert.ate.dev signer; trust its ClusterTrustBundle
  kubectl get clustertrustbundles -o json | python3 -c 'import json,sys
print("".join(b["spec"]["trustBundle"] for b in json.load(sys.stdin)["items"]
              if b["spec"].get("signerName", "").startswith("servicedns.podcert.ate.dev/")))' > "$HERE/.idp-ca.pem"
  [[ -s "$HERE/.idp-ca.pem" ]] || echo "warning: no servicedns.podcert.ate.dev ClusterTrustBundle; store-gate can't verify actor JWTs" >&2
  k create configmap idp-ca --from-file=ca.pem="$HERE/.idp-ca.pem" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

up() {
  need git go kind kubectl docker python3 openssl

  say "Agent Substrate $SUBSTRATE_REF on kind (Substrate's own dev path)"
  [[ -d "$SUBSTRATE_DIR/.git" ]] || git clone -q https://github.com/agent-substrate/substrate "$SUBSTRATE_DIR"
  git -C "$SUBSTRATE_DIR" fetch -q origin "$SUBSTRATE_REF" && git -C "$SUBSTRATE_DIR" checkout -q FETCH_HEAD
  if [[ -z "${PART7_REINSTALL:-}" ]] && kubectl -n ate-system rollout status deploy/ate-api-server --timeout=5s >/dev/null 2>&1; then
    echo "Substrate is already running on this cluster; skipping the install (PART7_REINSTALL=1 to redo it)"
  else
    ( cd "$SUBSTRATE_DIR" || exit 1
      hack/create-kind-cluster.sh
      ATE_INSTALL_KIND=true go run ./cmd/ate-setup deploy ate-system \
        --credential-provider='{"name":"k8s.io"}' \
        --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client )
  fi
  ( cd "$SUBSTRATE_DIR" && go install ./cmd/kubectl-ate )

  say "The highway image, the store, the lab STS and store-gate"
  docker build -q ${DOCKER_BUILD_FLAGS:-} -t "$IMAGE" "$REPO_ROOT/src" >/dev/null || \
    docker build --progress=plain ${DOCKER_BUILD_FLAGS:-} -t "$IMAGE" "$REPO_ROOT/src"   # rerun loudly to show the error
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
  idp_ca
  k rollout restart deploy >/dev/null   # pick up a rebuilt image (same tag) and the IdP CA
  k rollout status deploy --timeout=180s >/dev/null

  say "Grant the highway atespace the store-token Secret (provider default-deny; read at startup)"
  kubectl -n ate-system patch configmap k8s-credential-provider-namespace-policy --type merge -p \
    "{\"data\":{\"namespace-policy.yaml\":\"policies:\\n- atespace: $ATESPACE\\n  allowedNamespaces:\\n  - $NS\\n\"}}"
  kubectl -n ate-system rollout restart deployment/k8s-credential-provider >/dev/null
  kubectl -n ate-system rollout status deployment/k8s-credential-provider --timeout=120s >/dev/null

  say "The runner as an actor: atespace, worker pool (gVisor), template, actor"
  # Actor templates must pin images by digest, and the worker pool's ko:// image must be built:
  # push the highway image to the kind registry and let ko resolve the pool (as ate-setup does).
  local reg=localhost:5001 ref
  docker tag "$IMAGE" "$reg/$IMAGE"
  docker push "$reg/$IMAGE" >/dev/null || { echo "push to the kind registry ($reg) failed" >&2; exit 1; }
  # Ask the registry for the digest (RepoDigests is empty with Docker's containerd image store)
  local digest
  digest=$(curl -fsSI -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://$reg/v2/${IMAGE%%:*}/manifests/${IMAGE##*:}" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')
  [[ -n "$digest" ]] || { echo "could not read the digest of $reg/$IMAGE from the registry" >&2; exit 1; }
  ref="$reg/${IMAGE%%:*}@$digest"
  echo "actor image: $ref"
  ate get atespace "$ATESPACE" >/dev/null 2>&1 || ate create atespace "$ATESPACE"
  kubectl create ns "$ATESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ( cd "$SUBSTRATE_DIR" && KO_DOCKER_REPO=$reg go run github.com/google/ko@v0.18.0 resolve \
      --platform="linux/$(go env GOARCH)" -f "$HERE/manifests/workerpool.yaml" ) | kubectl apply -f -
  # Templates are immutable: if the runner image changed, recreate the template and the actor
  if ate get actor-template sandbox-runner -a "$ATESPACE" -o yaml 2>/dev/null | grep -q 'image:' &&
     ! ate get actor-template sandbox-runner -a "$ATESPACE" -o yaml | grep -qF "$ref"; then
    echo "runner image changed; recreating the template and $ACTOR"
    ate delete actor "$ACTOR" -a "$ATESPACE" || true
    ate delete actor-template sandbox-runner -a "$ATESPACE"
  fi
  if ! ate get actor-template sandbox-runner -a "$ATESPACE" >/dev/null 2>&1; then
    sed "s|IMAGE|$ref|" "$HERE/manifests/actor-template.yaml" > "$HERE/.actor-template.yaml"
    ate create actor-template -f "$HERE/.actor-template.yaml"
  fi
  say "Waiting for the template's golden snapshot (first boot of the runner under gVisor)"
  local st
  for _ in $(seq 120); do   # up to 10 min (status.goldenSnapshotStatus.goldenTag / errorMessage)
    st=$(ate get actor-template sandbox-runner -a "$ATESPACE" -o yaml 2>/dev/null || true)
    grep -q 'goldenTag:' <<<"$st" && break
    grep -q 'errorMessage:' <<<"$st" && { sed -n '/status:/,$p' <<<"$st"; echo "golden snapshot failed; see: task part7:doctor" >&2; exit 1; }
    sleep 5
  done
  sed -n '/status:/,$p' <<<"$st"
  ate get actor "$ACTOR" -a "$ATESPACE" >/dev/null 2>&1 || ate create actor "$ACTOR" -a "$ATESPACE" --template sandbox-runner
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
