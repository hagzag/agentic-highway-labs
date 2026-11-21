#!/usr/bin/env bash
# Part 6 as local processes (no cluster): mcp-tools with the store API, the
# sandbox-runner, the egress gateway, OPA, and a stand-in STS that mints permits.
# Captures the app-level story to captured/local/. The k3d run (run.sh) adds the
# mesh identity, NetworkPolicy and the black box.
#   needs: python3 with src/requirements.txt + uvicorn, opa, curl; `mcp-tools` resolving to 127.0.0.1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/practice/part6"
OUT="$HERE/captured/local"; TMP="$(mktemp -d)"; mkdir -p "$OUT" "$TMP/creds"
PY="${PY:-python3}"
export PYTHONPATH="$ROOT/src" LLM_MODE=mock STS_URL=http://127.0.0.1:8099
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
bg() { "$@" & pids+=($!); }
say() { printf '\n==> %s\n' "$*"; }
state() { curl -s localhost:8000/admin/state | "$PY" -c 'import json,sys; print("buckets:", [b["name"] for b in json.load(sys.stdin)["buckets"]])'; }
getent hosts mcp-tools >/dev/null || { echo "add '127.0.0.1 mcp-tools' to /etc/hosts"; exit 1; }

echo -n "lab-store-token-$RANDOM" > "$TMP/creds/store-token"
# No mesh locally, so no l5d-client-id: the local policy data lets caller "-" through.
"$PY" - "$HERE/policy/data.json" > "$TMP/data.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["lab"]["egress_callers"].append("-"); print(json.dumps(d))
EOF

bg "$PY" -m highway.lab_sts
STORE_TOKEN="$(cat "$TMP/creds/store-token")" PORT=8000 bg "$PY" -m highway.mcp_tools > "$TMP/mcp-tools.log" 2>&1
EGRESS_URL=http://127.0.0.1:8090 PORT=8001 bg "$PY" -m highway.runner > "$TMP/runner.log" 2>&1
bg opa run --server --addr=127.0.0.1:8181 --skip-version-check --log-level=error "$HERE/policy/egress.rego" "$TMP/data.json" > "$TMP/opa.log" 2>&1
gateway() {  # gateway <permits:true|false>
  [[ -n "${GW:-}" ]] && kill "$GW" 2>/dev/null && sleep 1
  EGRESS_PERMITS=$1 EGRESS_CRED_DIR="$TMP/creds" PORT=8090 "$PY" -m highway.egress_gateway >> "$TMP/egress-gateway.log" 2>&1 &
  GW=$!; pids+=("$GW")
  for _ in $(seq 20); do curl -sf localhost:8090/healthz >/dev/null && return; sleep 0.5; done
}
run_cleanup() { "$PY" "$HERE/local_call.py" "${1:-}"; }
for p in 8000 8001 8099 8181; do for _ in $(seq 20); do curl -s "localhost:$p" >/dev/null && break; sleep 0.5; done; done

{
say "PAVED: the runner holds no store credential, and the store refuses a call without one"
state
echo "direct DELETE, no credential: $(curl -s -X DELETE localhost:8000/store/v1/buckets/prod-archive)"

say "BREAK: EGRESS_PERMITS=false. The poisoned cleanup script asks the egress gateway"
gateway false
run_cleanup
state

say "FIX: EGRESS_PERMITS=true. Same script, now carrying the permit its run_script call was made with (tester)"
curl -s -X POST localhost:8000/admin/reset >/dev/null
gateway true
run_cleanup "$(curl -s 'localhost:8099/mint?scope=buckets:read+buckets:copy+scripts:run')"
state

say "Even ops-admin's permit (holds buckets:delete) can't spend the credential on a retention-locked bucket"
run_cleanup "$(curl -s 'localhost:8099/mint?scope=buckets:read+buckets:copy+buckets:delete+scripts:run&sub=ops-admin')"
state

say "No permit at all (a script that drops the header): DENY"
run_cleanup
} 2>&1 | tee "$OUT/01-run.txt"

grep -E 'egress=' "$TMP/egress-gateway.log" > "$OUT/egress-gateway.log"
grep -E 'store=|admin=' "$TMP/mcp-tools.log" > "$OUT/mcp-tools.log"
grep -E 'runner=' "$TMP/runner.log" > "$OUT/runner.log"
say "Captured to $OUT"
