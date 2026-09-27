#!/usr/bin/env bash
# Part 5 — The Black Box: replay the crash, and this time name the human, the agent and the task.
#   ./run.sh            run every step
#   ./run.sh <step>     up | break | record | replay | forge | tamper | verify | blind | capture | doctor
# Break first: with only pod logs, "who shipped the token?" and "who deleted prod-archive?"
# have no honest answer. Then every hop signs what it saw into a hash-chained, anchored tape.
source "$(dirname "$0")/../../scripts/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
P4="$HERE/../part4/run.sh"
OUT="$HERE/captured/k3d"
TD=highway.lab
SS() { kubectl -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
planner() { kubectl -n "$NS" exec deploy/planner-agent -c planner -- "$@"; }
rogue() { kubectl -n "$NS" exec deploy/rogue -c rogue -- "$@"; }
audit_cli() { kubectl -n "$NS" exec -i deploy/audit -c audit -- python -m highway.audit "$@"; }
show() { applogs "$1" "$2" "$3" | grep -E "$4" || true; }

# Every hop that writes to the black box: deploy:container
EMITTERS="sts:sts planner-agent:planner executor-agent:executor mcp-gateway:gateway mcp-tools:mcp-tools sandbox-runner:sandbox-runner"

wait_svid() {  # wait_svid deploy:container ...   (same check as Part 3)
  local py='from highway import svid; svid.token("probe")'
  for pair in "$@"; do
    for i in $(seq 30); do
      kubectl -n "$NS" exec "deploy/${pair%:*}" -c "${pair#*:}" -- python -c "$py" >/dev/null 2>&1 \
        && { echo "${pair%:*}: SVID issued"; break; }
      [[ $i == 30 ]] && { echo "${pair%:*}: no SVID after 60s, run: ./run.sh doctor"; return 1; }
      sleep 2
    done
  done
}

plan_as() {  # plan_as <task-id> <user>
  local tok; tok=$(planner python -m highway.login --user "$2")
  planner python -m highway.planner --task-id "$1" --user-token "$tok"
}

exfil() {  # Part 4's crash: poisoned note -> run_script -> the runner's SA token to the sink
  tools_admin reset >/dev/null
  tools_admin poison-exfil >/dev/null
  queue_flush
  plan_as "$1" tester >/dev/null
  sleep 10
}

sink_ip() {
  kubectl -n internet logs deploy/sink --tail=-1 2>/dev/null | grep 'sink=received' | tail -1 \
    | sed -n 's/.*src=\([^ ]*\).*/\1/p'
}

pod_by_ip() {
  local p
  p=$(kubectl get pods -A -o jsonpath="{range .items[?(@.status.podIP==\"$1\")]}{.metadata.namespace}/{.metadata.name}{end}")
  echo "${p:-<no pod has this IP any more>}"
}

# recorder_on: AUDIT_URL on every hop, plus the SPIRE socket where a hop never needed
# an SVID before (mcp-tools, sandbox-runner). Strategic merge: env/volumes merge by name.
SPIRE_VOL='{"name":"spire","hostPath":{"path":"/run/spire/agent-sockets","type":"Directory"}}'
SPIRE_MNT='{"name":"spire","mountPath":"/run/spire/sockets","readOnly":true}'
audit_env() {  # audit_env <deploy> <container> [extra env objects...]
  local d=$1 c=$2 env='{"name":"AUDIT_URL","value":"http://audit:8080"}'
  shift 2
  for e in "$@"; do env+=",$e"; done
  kubectl -n "$NS" patch deploy "$d" --type strategic -p \
    "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[$SPIRE_VOL],\"containers\":[{\"name\":\"$c\",\"env\":[$env],\"volumeMounts\":[$SPIRE_MNT]}]}}}}" >/dev/null
}

recorder_on() {
  for p in $EMITTERS; do
    case "${p%:*}" in
      mcp-gateway)    audit_env "${p%:*}" "${p#*:}" '{"name":"AUDIT_REQUIRED","value":"true"}' ;;
      sandbox-runner) audit_env "${p%:*}" "${p#*:}" '{"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}' ;;
      *)              audit_env "${p%:*}" "${p#*:}" ;;
    esac
  done
}

recorder_off() {  # a re-run of `up` must start from the break, not from a recorder left on
  for p in $EMITTERS; do
    kubectl -n "$NS" set env "deploy/${p%:*}" -c "${p#*:}" AUDIT_URL- AUDIT_REQUIRED- POD_IP- >/dev/null 2>&1 || true
  done
}

audit_verify() {  # verify the tape against the latest anchored checkpoint
  sleep 2   # the checkpoint is written just after the append
  kubectl -n "$NS" get configmap audit-checkpoints -o jsonpath='{.data.latest}' \
    | audit_cli verify --checkpoint - || true
}

up() {
  say "Part 4 road first (Keycloak, SPIRE, STS, gateways, sink, sandbox-runner)"
  "$P4" up

  say "Rewind to the crash: fence OFF, recorder OFF (the black box is for the crash)"
  kubectl -n "$NS" delete netpol mcp-tools-ingress runner-egress --ignore-not-found >/dev/null
  kubectl -n internet delete netpol sink-ingress --ignore-not-found >/dev/null
  recorder_off
  wait_ready

  say "The black box: audit collector (hash-chained tape on a PVC, signed checkpoints in a ConfigMap)"
  for sa in audit sandbox-runner; do   # the runner never needed an SVID before; now it signs
    SS entry create -parentID "spiffe://$TD/k8s-node" -spiffeID "spiffe://$TD/ns/$NS/sa/$sa" \
      -selector "k8s:ns:$NS" -selector "k8s:sa:$sa" >/dev/null 2>&1 || true
  done
  kubectl apply -f "$HERE/manifests/00-audit.yaml" >/dev/null
  kubectl -n "$NS" rollout status deploy/audit --timeout=180s >/dev/null
  wait_svid audit:audit
  kubectl -n "$NS" get pods -l app=audit; kubectl -n "$NS" get pvc audit-log
}

break_it() {
  say "BREAK: the crash again, recorder OFF (task 70): poisoned note -> run_script exfil; rogue deletes prod-archive"
  exfil 70
  rogue python -m highway.forge bypass-framed 2>&1 | grep forge= || true
  local ip; ip=$(sink_ip)

  say "Q1: the sink holds a stolen token. Whose pod sent it?"
  kubectl -n internet logs deploy/sink --tail=1 | grep 'sink=received' || echo "(sink: nothing received)"
  echo "pod with src=$ip: $(pod_by_ip "$ip")"
  show sandbox-runner sandbox-runner 120 'runner='
  echo "A name (sub=tester) and a byte count. No task, no permit, no agent; nothing that joins it to the planner's log."

  say "Q2: prod-archive is gone. Who? mcp-tools' log names a human"
  show mcp-tools mcp-tools 120 'tool=delete_bucket'
  echo "permits the STS ever issued to hagzag: $(applogs sts sts | grep -c 'sts=issued sub=hagzag' || true)"
  echo "hagzag never logged in. sub= is a header the rogue typed (Part 1's requested_by, again)."

  say "And the evidence dies with the pod: restart the runner"
  local before after
  before=$(applogs sandbox-runner sandbox-runner | grep -c 'runner=run_script' || true)
  kubectl -n "$NS" rollout restart deploy/sandbox-runner >/dev/null
  kubectl -n "$NS" rollout status deploy/sandbox-runner --timeout=120s >/dev/null
  wait_ready
  after=$(applogs sandbox-runner sandbox-runner | grep -c 'runner=run_script' || true)
  echo "runner=run_script lines: before restart $before, after $after. pod with src=$ip: $(pod_by_ip "$ip")"
}

record() {
  say "FIX: recorder ON. Every hop signs what it saw (X.509-SVID) and ships it to the black box"
  recorder_on
  wait_ready
  wait_svid sts:sts planner-agent:planner executor-agent:executor mcp-gateway:gateway \
            mcp-tools:mcp-tools sandbox-runner:sandbox-runner
  echo "mcp-gateway: AUDIT_REQUIRED=true (no record, no action)"

  say "The same crash, recorder ON (task 71), and the same framed bypass"
  exfil 71
  rogue python -m highway.forge bypass-framed 2>&1 | grep forge= || true
  sleep 2

  say "What the black box accepted (signature chains to SPIRE; signer may write that kind)"
  show audit audit 120 'audit=(appended|REJECTED)'
  show audit audit 120 'audit=checkpoint' | tail -1
}

replay() {
  local ip; ip=$(sink_ip)
  say "Incident 1: the sink holds a token sent from $ip. Replay the tape from that IP"
  audit_cli replay --ip "$ip"
  say "Incident 2: prod-archive is gone and mcp-tools' log says hagzag. Replay the tape from the bucket"
  audit_cli replay --bucket prod-archive
}

forge() {
  say "The rogue plants evidence: a gateway ALLOW for the delete, naming hagzag (unsigned, then self-signed)"
  rogue python -m highway.forge audit-forge 2>&1 | grep forge= || true
  show audit audit 30 'audit=REJECTED'
}

tamper() {
  say "Before: verify the tape against the anchored checkpoint"
  audit_verify
  say "The insider (write access to the audit volume): the gateway's run_script ALLOW now says ops-admin; hash chain recomputed"
  kubectl -n "$NS" exec deploy/audit -c audit -- python -m highway.forge audit-rewrite
  say "After: the chain links up (rechained), but the gateway's signature and the anchored head don't"
  audit_verify
  say "Replay still names the right human, and says which record lies"
  audit_cli replay --ip "$(sink_ip)" | sed -n '/^VERDICT/,$p'
}

blind() {
  say "No record, no action: the black box goes dark (scaled to 0); a benign task (72) starts"
  kubectl -n "$NS" scale deploy/audit --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app=audit --timeout=90s >/dev/null 2>&1 || true
  tools_admin reset >/dev/null
  queue_flush
  plan_as 72 tester >/dev/null 2>&1 || echo "planner: task 72 failed (its first tool call was refused)"
  sleep 3
  show mcp-gateway gateway 30 'audit=dropped|gateway=DENY.*task_id=72'
  kubectl -n "$NS" scale deploy/audit --replicas=1 >/dev/null
  kubectl -n "$NS" rollout status deploy/audit --timeout=120s >/dev/null
  wait_ready
}

doctor() {
  say "Pods"; kubectl -n "$NS" get pods -o wide
  say "SPIRE entries"; SS entry show -selector "k8s:ns:$NS" | grep -E 'SPIFFE ID' | sort
  say "Recorder env per hop"
  kubectl -n "$NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].env[?(@.name=="AUDIT_URL")].value}{"\n"}{end}'
  say "Tape + checkpoint"
  kubectl -n "$NS" exec deploy/audit -c audit -- sh -c 'wc -l < /var/lib/audit/audit.jsonl' 2>/dev/null || echo "(no tape yet)"
  kubectl -n "$NS" get configmap audit-checkpoints -o jsonpath='{.data.latest}' | cut -c1-60; echo
  say "Collector: recent rejections / errors"
  applogs audit audit 600 | grep -E 'REJECTED|error' | tail -5 || true
  say "Emitters: dropped events"
  for p in $EMITTERS; do applogs "${p%:*}" "${p#*:}" 600 | grep 'audit=dropped' | tail -2 || true; done
}

capture() {
  mkdir -p "$OUT"
  up        2>&1 | tee "$OUT/00-up.txt"
  break_it  2>&1 | tee "$OUT/01-break.txt"
  record    2>&1 | tee "$OUT/02-record.txt"
  replay    2>&1 | tee "$OUT/03-replay.txt"
  forge     2>&1 | tee "$OUT/04-forge.txt"
  audit_cli dump > "$OUT/tape-before-tamper.jsonl" 2>/dev/null || true
  tamper    2>&1 | tee "$OUT/05-tamper.txt"
  blind     2>&1 | tee "$OUT/06-blind.txt"
  applogs audit audit > "$OUT/audit.log"
  applogs mcp-gateway gateway > "$OUT/mcp-gateway.log"
  applogs mcp-tools mcp-tools > "$OUT/mcp-tools.log"
  applogs sts sts > "$OUT/sts.log"
  say "Captured to $OUT"
}

preflight() {
  if ! kubectl -n "$NS" get deploy audit sandbox-runner >/dev/null 2>&1 \
     || ! planner python -c 'import highway.audit' >/dev/null 2>&1; then
    echo "Part 5 isn't installed on this cluster (or the image predates it)." >&2
    echo "Run: task part5:up   (rebuilds highway-agent:dev, deploys Part 4 and the audit collector)" >&2
    exit 1
  fi
}
case "${1:-all}" in break|record|replay|forge|tamper|verify|blind) preflight ;; esac

case "${1:-all}" in
  up) up ;; break) break_it ;; record) record ;; replay) replay ;; forge) forge ;;
  tamper) tamper ;; verify) audit_verify ;; blind) blind ;; capture) capture ;; doctor) doctor ;;
  all) up; break_it; record; replay; forge; tamper; blind ;;
  *) echo "unknown step: $1"; exit 1 ;;
esac
