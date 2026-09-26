#!/usr/bin/env bash
# Part 4 — The Closed Track: shrink an agent tool's blast radius from the outside.
#   ./run.sh            run every step
#   ./run.sh <step>     up | probe-before | break | gvisor | fence | verify | probe-after | report | capture | doctor
# A code-running MCP tool (run_script) starts unfenced (runc, SA token, open egress).
# The fence is NetworkPolicy + no token + gVisor. break-first, then close it.
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
P3="$HERE/../part3/run.sh"
OUT="$HERE/captured/k3d"
planner() { kubectl -n "$NS" exec deploy/planner-agent -c planner -- "$@"; }
rogue() { kubectl -n "$NS" exec deploy/rogue -c rogue -- "$@"; }
show() { applogs "$1" "$2" "$3" | grep -E "$4" || true; }
dump() {  # dump <phase> — persist every relevant log so a crash still leaves evidence
  local ph="${1:-x}"; mkdir -p "$OUT"
  applogs sandbox-runner sandbox-runner > "$OUT/$ph-runner.log" 2>/dev/null || true
  applogs executor-agent executor      > "$OUT/$ph-executor.log" 2>/dev/null || true
  applogs mcp-gateway gateway          > "$OUT/$ph-gateway.log" 2>/dev/null || true
  applogs llm-gateway llm-gateway      > "$OUT/$ph-llm-gateway.log" 2>/dev/null || true
  kubectl -n internet logs deploy/sink --tail=-1 > "$OUT/$ph-sink.log" 2>/dev/null || true
}

plan_as() {  # plan_as <task-id> <user>
  local tok; tok=$(planner python -m highway.login --user "$2")
  planner python -m highway.planner --task-id "$1" --user-token "$tok"
}

# runtimeClassName for the fenced runner: gvisor if the RuntimeClass exists AND a
# runsc smoke pod runs; otherwise strip the line so the pod runs on runc.
runtime_class() {
  kubectl get runtimeclass gvisor >/dev/null 2>&1 || { echo ""; return; }
  kubectl -n "$NS" run runsc-smoke --rm -i --restart=Never --image="$IMAGE" \
    --overrides='{"spec":{"runtimeClassName":"gvisor"}}' --command -- true >/dev/null 2>&1 \
    && echo "gvisor" || echo ""
}

apply_runner() {  # apply_runner <runtime-class-or-empty>
  if [[ -n "$1" ]]; then
    sed "s/RUNTIME_CLASS/$1/" "$HERE/manifests/40-runner-fenced.yaml" | kubectl apply -f - >/dev/null
  else
    grep -v 'runtimeClassName: RUNTIME_CLASS' "$HERE/manifests/40-runner-fenced.yaml" | kubectl apply -f - >/dev/null
  fi
}

# probe_matrix <title> -> a markdown table from every pod's point of view
probe_matrix() {
  say "$1"
  local pods="sandbox-runner:sandbox-runner executor-agent:executor rogue:rogue"
  printf '| pod | runtime | sa_token | mcp-tools:8000 | kube-api:443 | sink:9000 |\n'
  printf '|---|---|---|---|---|---|\n'
  for p in $pods; do
    local raw rt tok mt ka sk
    raw=$(kubectl -n "$NS" exec "deploy/${p%:*}" -c "${p#*:}" -- \
      python -m highway.probe --targets mcp-tools:8000,kubernetes.default:443,sink.internet:9000 2>/dev/null || true)
    rt=$(sed -n 's/.*runtime=\([^ ]*\).*/\1/p' <<<"$raw" | head -1)
    tok=$(sed -n 's/.*sa_token=\([^ ]*\).*/\1/p' <<<"$raw" | head -1)
    mt=$(grep 'target=mcp-tools' <<<"$raw" | sed 's/.*result=//')
    ka=$(grep 'target=kubernetes' <<<"$raw" | sed 's/.*result=//')
    sk=$(grep 'target=sink' <<<"$raw" | sed 's/.*result=//')
    printf '| %s | %s | %s | %s | %s | %s |\n' "${p%:*}" "${rt:-?}" "${tok:-?}" "${mt:-?}" "${ka:-?}" "${sk:-?}"
  done
}

up() {
  say "Part 3 road first (Keycloak, SPIRE, STS, gateways) with delegation ON"
  "$P3" up
  "$P3" llm-gw >/dev/null
  kubectl -n "$NS" patch configmap highway-permits --type merge \
    -p '{"data":{"PERMITS":"true","MCP_URL":"http://mcp-gateway:8080/mcp"}}' >/dev/null

  say "The internet (sink) and the sandbox-runner (run_script), no fence yet"
  kubectl apply -f "$HERE/manifests/10-sink.yaml" >/dev/null
  kubectl apply -f "$HERE/manifests/20-sandbox-runner.yaml" >/dev/null
  kubectl annotate ns internet linkerd.io/inject=disabled --overwrite >/dev/null
  kubectl label ns internet kubernetes.io/metadata.name=internet --overwrite >/dev/null

  say "Teach the gateway where run_script lives; restart agents with permits ON"
  kubectl -n "$NS" set env deploy/mcp-gateway UPSTREAM_RUNNER_URL="http://sandbox-runner:8000/mcp" >/dev/null
  kubectl -n "$NS" rollout restart deploy/planner-agent deploy/executor-agent >/dev/null
  kubectl -n internet rollout status deploy/sink --timeout=120s >/dev/null
  wait_ready
  kubectl -n "$NS" get pods -l app=sandbox-runner; kubectl -n internet get pods
}

exfil() {  # the poisoned-note -> run_script -> token theft path
  tools_admin reset >/dev/null
  tools_admin poison-exfil >/dev/null
  queue_flush
  plan_as "${1:-70}" tester >/dev/null
  sleep 6
}

break_it() {
  say "BREAK 1: Part 3's bypass still works — rogue reaches mcp-tools directly"
  tools_admin reset >/dev/null
  rogue python -m highway.forge bypass 2>&1 | grep forge= || true

  say "BREAK 2: a poisoned note makes the agent run a script that steals its token"
  exfil 70
  show executor-agent executor 30 "executor=(task|script_out).*(run diagnostics|read_token)"
  say "The runner ran it; the script read the token and shipped it"
  show sandbox-runner sandbox-runner 30 'runner='
  say "The sink caught the token (bytes ~ 1000 = a real ServiceAccount token)"
  kubectl -n internet logs deploy/sink --tail=5 | grep 'sink=received' || echo "(sink: nothing received)"
  dump break
}

gvisor() {
  say "Installing gVisor on the k3d node (best-effort; needs docker on the host)"
  kubectl apply -f "$HERE/manifests/00-runtimeclass.yaml" >/dev/null
  bash "$HERE/gvisor/install-gvisor.sh" || echo "gVisor install failed; fence will fall back to runc"
}

fence() {
  say "FENCE: NetworkPolicy (gateway is the only road; runner can't phone home)"
  kubectl label ns internet kubernetes.io/metadata.name=internet --overwrite >/dev/null
  kubectl apply -f "$HERE/manifests/30-fence.yaml" >/dev/null

  local rc; rc=$(runtime_class)
  say "FENCE: runner with no SA token, runtime=${rc:-runc}"
  apply_runner "$rc"
  kubectl -n "$NS" rollout status deploy/sandbox-runner --timeout=120s >/dev/null
  wait_ready
  [[ -z "$rc" ]] && echo "note: runsc not available on this node; runner is on runc. NetworkPolicy + no-token still apply."

  say "Waiting for kube-router to program the new pod's NetworkPolicy (startup window)"
  local r=REACH
  for _ in $(seq 15); do   # up to ~30s; egress rules lag a fresh pod (k3s#14711)
    r=$(kubectl -n "$NS" exec deploy/sandbox-runner -c sandbox-runner -- \
      python -m highway.probe --targets sink.internet:9000 2>/dev/null | sed -n 's/.*result=//p')
    [[ "$r" == BLOCKED ]] && break
    sleep 2
  done
  if [[ "$r" == BLOCKED ]]; then
    echo "egress: ENFORCED (runner -> sink is BLOCKED)"
  else
    echo "egress: still $r after 30s. kube-router egress can be racy on k3d + a mesh;"
    echo "        the dropped token neutralises the exfil regardless. For reliable egress"
    echo "        use a CNI like Cilium/Calico or an egress gateway."
  fi
}

verify() {
  say "VERIFY 1: the bypass is now dead — rogue can't reach mcp-tools"
  tools_admin reset >/dev/null
  rogue python -m highway.forge bypass 2>&1 | grep forge= || true

  say "VERIFY 2: the same poisoned run_script now finds nothing to steal and nowhere to send it"
  exfil 71
  show executor-agent executor 30 "executor=script_out"
  say "Sink log unchanged — no 'received' line for this run"
  kubectl -n internet logs deploy/sink --tail=3 | grep 'sink=received' || echo "(sink: nothing received)"
  dump verify
}

report() {
  mkdir -p "$OUT"
  { probe_matrix "Blast radius BEFORE the fence"; echo; } | tee "$OUT/blast-before.md"
}

doctor() {
  say "Pods"; kubectl -n "$NS" get pods -o wide; kubectl -n internet get pods
  say "NetworkPolicies"; kubectl -n "$NS" get netpol; kubectl -n internet get netpol
  say "RuntimeClass + runner runtime"
  kubectl get runtimeclass 2>/dev/null || true
  kubectl -n "$NS" get pod -l app=sandbox-runner -o jsonpath='{.items[0].spec.runtimeClassName}{"\n"}' || true
  say "Recent runner / sink"
  applogs sandbox-runner sandbox-runner 600 | tail -5 || true
  kubectl -n internet logs deploy/sink --tail=5 || true
}

capture() {
  mkdir -p "$OUT"
  up                                   2>&1 | tee "$OUT/00-up.txt"
  probe_matrix "Blast radius BEFORE"   2>&1 | tee "$OUT/01-blast-before.md"
  break_it                             2>&1 | tee "$OUT/02-break.txt"
  gvisor                               2>&1 | tee "$OUT/03-gvisor.txt"
  fence                                2>&1 | tee "$OUT/04-fence.txt"
  verify                               2>&1 | tee "$OUT/05-verify.txt"
  probe_matrix "Blast radius AFTER"    2>&1 | tee "$OUT/06-blast-after.md"
  say "Captured to $OUT"
}

case "${1:-all}" in
  up) up ;; probe-before) probe_matrix "Blast radius BEFORE the fence" ;; break) break_it ;;
  gvisor) gvisor ;; fence) fence ;; verify) verify ;;
  probe-after) probe_matrix "Blast radius AFTER the fence" ;; report) report ;;
  doctor) doctor ;; capture) capture ;;
  all) up; probe_matrix "Blast radius BEFORE"; break_it; gvisor; fence; verify; probe_matrix "Blast radius AFTER" ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
