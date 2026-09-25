#!/usr/bin/env bash
# Maintainer smoke test: runs the same Python code as the pods, as local processes.
# No cluster, no mesh. Used to validate the agents and to capture app-level output.
# Needs: python3 + src/requirements.txt, redis-server, (optional) tcpdump.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/.smoke}"; mkdir -p "$OUT"
export PYTHONPATH="$ROOT/src" LLM_MODE="${LLM_MODE:-mock}"
export REDIS_URL=redis://127.0.0.1:6379/0 MCP_URL=http://127.0.0.1:8000/mcp

start() {
  redis-server --port 6379 --save '' --daemonize yes >/dev/null
  python3 -m highway.mcp_tools >"$OUT/mcp-tools.log" 2>&1 & echo $! >"$OUT/mcp.pid"
  for _ in $(seq 20); do curl -sf localhost:8000/healthz >/dev/null && break; sleep 0.5; done
  python3 -m highway.executor >"$OUT/executor.log" 2>&1 & echo $! >"$OUT/exec.pid"
}
stop() {
  kill "$(cat "$OUT/mcp.pid" 2>/dev/null)" "$(cat "$OUT/exec.pid" 2>/dev/null)" 2>/dev/null || true
  redis-cli shutdown nosave >/dev/null 2>&1 || true
}
case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop"; exit 1 ;;
esac
