#!/usr/bin/env bash
# Part 8 — OpenShell: the same break, a different kind of fence.
#   ./run.sh            run every step
#   ./run.sh <step>     up | paved | break | l7 | prove | gate | capture | down
# OpenShell (NVIDIA, CNCF Sandbox) runs the agent in a sandbox whose every file access,
# syscall and connection goes through a supervisor. Credentials are providers: the agent
# sees a placeholder, the proxy adds the real value at an approved endpoint.
# Runs on Docker (Linux or macOS on Apple Silicon): no cluster.
#
# Captured end to end on 2026-11-22 (macOS, Docker Desktop, OpenShell 0.1.9 from Homebrew).
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/captured/docker"
SBX=highway
NET=highway-part8
TOKEN_FILE="$HERE/.store-token"
SBX_IMAGE=highway-sandbox:dev   # the highway image plus a non-root user: the sandbox identity needs a usable WORKDIR
dk() { docker run -d --network "$NET" --restart=no "$@" >/dev/null; }
state() { curl -s localhost:8000/admin/state | python3 -c 'import json,sys; print("buckets:", [b["name"] for b in json.load(sys.stdin)["buckets"]])'; }
reset() { curl -s -X POST localhost:8000/admin/reset >/dev/null; }
permit() { curl -s "localhost:8099/mint?scope=${1// /+}&sub=${2:-tester}"; }
sandbox_rm() {  # delete the sandbox and wait: deletion is asynchronous, and the name (and any
  # provider attached to it) stays taken until cleanup finishes
  openshell sandbox delete "$SBX" >/dev/null 2>&1 || true
  for _ in $(seq 60); do openshell sandbox get "$SBX" >/dev/null 2>&1 || return 0; sleep 1; done
  echo "sandbox $SBX still present after 60s" >&2; return 1
}
sandbox() {  # sandbox <policy-file> [--provider X]: (re)create the sandbox with this policy
  sandbox_rm
  openshell sandbox create --name "$SBX" --from "$SBX_IMAGE" --policy "$HERE/policy/$1" "${@:2}" --detach -- sleep infinity
}
run_py() {  # run_py <script> [args...]: run a script inside the sandbox
  openshell sandbox exec --name "$SBX" -- python -c "$(cat "$HERE/scripts/$1")" "${@:2}"
}

GW="$HERE/.gateway"
gateway_up() {  # a local OpenShell gateway (mTLS, docker driver), unless one is already connected
  # NVIDIA's install.sh runs this as a service; Homebrew's core formula installs only the
  # binaries. Same shape here: mTLS for the CLI, gateway-minted JWTs for the sandboxes.
  openshell status 2>/dev/null | grep -q 'Status: Connected' && return
  command -v openshell-gateway >/dev/null || { echo "missing: openshell-gateway"; exit 1; }
  say "Starting a local OpenShell gateway (127.0.0.1:17670, docker driver; state in $GW)"
  mkdir -p "$GW"
  # PKI: server cert, CA, the CLI's client cert (also written to ~/.config/openshell), JWT keys
  [[ -s "$GW/pki/jwt/kid" ]] || openshell-gateway generate-certs --output-dir "$GW/pki" >/dev/null
  # Sandboxes sit on Docker's bridge. On Docker Desktop, host.docker.internal reaches the
  # loopback-bound gateway, and it's in the server cert's SANs.
  printf '[openshell]\nversion = 2\n\n[openshell.gateway]\nguest_tls_ca = "%s"\n\n[openshell.drivers.docker]\ngrpc_endpoint = "https://%s:17670"\n' \
    "$GW/pki/ca.crt" "${OPENSHELL_GUEST_HOST:-host.docker.internal}" > "$GW/gateway.toml"
  OPENSHELL_LOCAL_TLS_DIR="$GW/pki" OPENSHELL_TELEMETRY_ENABLED=false nohup openshell-gateway \
    --config "$GW/gateway.toml" --compute-driver docker --db-url "sqlite://$GW/gateway.db?mode=rwc" \
    > "$GW/gateway.log" 2>&1 &
  echo $! > "$GW/gateway.pid"
  openshell gateway add https://127.0.0.1:17670 --local --name openshell >/dev/null 2>&1 || true
  openshell gateway select openshell >/dev/null 2>&1 || true
  for _ in $(seq 30); do openshell status 2>/dev/null | grep -q 'Status: Connected' && return; sleep 1; done
  echo "gateway did not come up:" >&2; tail -20 "$GW/gateway.log" >&2; exit 1
}

up() {
  need docker curl python3
  if ! command -v openshell >/dev/null; then
    say "Installing OpenShell (CLI, gateway, prover)"
    if command -v brew >/dev/null; then brew install openshell
    else curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh; fi
  fi
  openshell --version
  command -v openshell-prover >/dev/null || echo "note: openshell-prover not installed; 'prove' will be skipped (brew/apt/rpm/snap)"
  gateway_up

  say "The highway image, the store (with its REST API), the lab STS, store-gate + OPA"
  docker build -q -t "$IMAGE" "$REPO_ROOT/src"
  printf 'FROM %s\nRUN useradd -m -u 1000 -s /bin/bash sandbox && mkdir -p /sandbox && chown sandbox:sandbox /sandbox\nUSER sandbox\nWORKDIR /sandbox\n' "$IMAGE" \
    | docker build -q -t "$SBX_IMAGE" -
  docker network create "$NET" >/dev/null 2>&1 || true
  [[ -s "$TOKEN_FILE" ]] || openssl rand -hex 12 | sed 's/^/store-/' > "$TOKEN_FILE"
  docker rm -f highway-store highway-sts highway-gate highway-opa >/dev/null 2>&1 || true
  dk --name highway-store -p 8000:8000 -e STORE_TOKEN="$(cat "$TOKEN_FILE")" "$IMAGE" python -m highway.mcp_tools
  dk --name highway-sts -p 8099:8099 -e HOST=0.0.0.0 "$IMAGE" python -m highway.lab_sts
  # No mesh, and OpenShell doesn't pass a sandbox identity upstream: the gate sees caller "-".
  python3 - "$REPO_ROOT/practice/part6/policy/data.json" > "$HERE/.data.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["lab"]["egress_callers"] = ["-"]; print(json.dumps(d))
EOF
  dk --name highway-opa -v "$REPO_ROOT/practice/part6/policy/egress.rego:/policy/egress.rego:ro" \
    -v "$HERE/.data.json:/policy/data.json:ro" "openpolicyagent/opa:$OPA_VERSION" \
    run --server --addr=0.0.0.0:8181 --log-level=error /policy/egress.rego /policy/data.json
  dk --name highway-gate -p 8090:8090 -v "$TOKEN_FILE:/var/run/egress/store-token:ro" \
    -e PORT=8090 -e EGRESS_PERMITS=true -e OPA_URL=http://highway-opa:8181/v1/data/highway/egress/decision \
    -e STS_URL=http://highway-sts:8099 -e STS_ISSUER=http://sts.migration.svc.cluster.local:8080 \
    -e EGRESS_POLICY='{"highway-store:8000": {"prefix": "/store/", "credential": "store-token", "header": "Authorization", "value_prefix": "Bearer "}}' \
    "$IMAGE" python -m highway.egress_gateway
  for p in 8000 8099 8090; do for _ in $(seq 30); do curl -s "localhost:$p/healthz" >/dev/null && break; sleep 1; done; done
  state

  say "Provider: the store token, usable only at host.openshell.internal:8000"
  # Re-runnable: lint refuses an id that already exists, so drop the sandbox (it holds the
  # provider), the provider (it holds the profile) and then the profile
  sandbox_rm
  openshell provider delete highway-store >/dev/null 2>&1 || true
  openshell profile delete highway-store >/dev/null 2>&1 || true
  openshell profile lint -f "$HERE/policy/profile-store.yaml"
  openshell profile import -f "$HERE/policy/profile-store.yaml"
  openshell provider create --name highway-store --type highway-store --credential STORE_TOKEN="$(cat "$TOKEN_FILE")"
  openshell provider list
}

paved() {
  say "PAVED: Part 4's exfil in an OpenShell sandbox (store provider attached)"
  sandbox sandbox-break.yaml --provider highway-store
  run_py exfil.py
}

break_it() {
  say "BREAK: the poisoned cleanup script, full access to the store, provider attached"
  reset; state
  sandbox sandbox-break.yaml --provider highway-store
  run_py cleanup.py http://host.openshell.internal:8000
  state
}

l7() {
  say "FIX A (OpenShell-native): L7 rules. GET allowed, DELETE prod-archive denied"
  reset
  sandbox sandbox-l7.yaml --provider highway-store
  run_py cleanup.py http://host.openshell.internal:8000
  state
  echo "Static: this is the answer for every task and every human in this sandbox, not for this delegation."
}

prove() {
  say "The prover, as a CI gate: does a candidate policy stay inside the platform boundary?"
  command -v openshell-prover >/dev/null || { echo "openshell-prover not installed; skipping"; return; }
  for c in sandbox-break.yaml sandbox-l7.yaml; do
    echo "--- $c"
    # The L7 candidate takes ~50s on an M-series Mac; the default 10s budget ends "inconclusive"
    openshell-prover check "$HERE/policy/$c" --boundary "$HERE/policy/boundary.yaml" --timeout "${PROVER_TIMEOUT:-2m}" || true
  done
}

gate() {
  say "FIX B (delegation): the sandbox reaches only store-gate; the gate holds the token and checks the permit"
  reset
  sandbox sandbox-gate.yaml
  say "tester's permit"
  run_py cleanup.py http://host.openshell.internal:8090/highway-store:8000 "$(permit 'buckets:read buckets:copy scripts:run')"
  say "ops-admin's permit (holds buckets:delete)"
  run_py cleanup.py http://host.openshell.internal:8090/highway-store:8000 "$(permit 'buckets:read buckets:delete scripts:run' ops-admin)"
  state
  docker logs highway-gate 2>&1 | grep -E 'egress=' | tail -6
}

capture() {
  mkdir -p "$OUT"
  up       2>&1 | tee "$OUT/00-up.txt"
  paved    2>&1 | tee "$OUT/01-paved.txt"
  break_it 2>&1 | tee "$OUT/02-break.txt"
  l7       2>&1 | tee "$OUT/03-l7.txt"
  prove    2>&1 | tee "$OUT/04-prove.txt"
  gate     2>&1 | tee "$OUT/05-gate.txt"
  docker logs highway-gate > "$OUT/store-gate.log" 2>&1
  say "Captured to $OUT"
}

down() {
  openshell sandbox delete "$SBX" >/dev/null 2>&1 || true
  docker rm -f highway-store highway-sts highway-gate highway-opa >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [[ -s "$GW/gateway.pid" ]] && kill "$(cat "$GW/gateway.pid")" 2>/dev/null; rm -f "$GW/gateway.pid"
}

case "${1:-all}" in
  up) up ;; paved) paved ;; break) break_it ;; l7) l7 ;; prove) prove ;; gate) gate ;;
  capture) capture ;; down) down ;;
  all) up; paved; break_it; l7; prove; gate ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
