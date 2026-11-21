#!/usr/bin/env bash
# Runs inside the Lima VM (see lima.yaml): run.sh <step> with Go and kubectl-ate on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PART7_IN_VM=1
export SUBSTRATE_DIR="${SUBSTRATE_DIR:-$HOME/substrate}"   # build on the VM's disk, not the mount
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# Outbound network check. Lima's user-mode network may hand out IPv6 answers it can't route:
# if IPv4 works and the default doesn't, prefer IPv4 for good.
net() { curl -fsS -o /dev/null -m 10 "$@" https://pypi.org/simple/; }
if ! net; then
  if net -4; then
    echo "==> IPv6 is unreachable in the VM; preferring IPv4"
    echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf >/dev/null
  else
    echo "The VM has no outbound network. Diagnostics:" >&2
    ip -br addr >&2; ip route >&2; resolvectl status 2>/dev/null | grep -E 'DNS Servers|Current DNS' >&2 || true
    getent ahosts pypi.org >&2 || echo "DNS: pypi.org does not resolve" >&2
    curl -4 -sS -m 10 -o /dev/null https://pypi.org/simple/ >&2 || true
    echo "Check a VPN or proxy on the Mac, then: task part7:vm-down && task part7:all" >&2
    exit 1
  fi
fi
for b in docker kind kubectl go; do command -v "$b" >/dev/null || { echo "missing in VM: $b (provisioning failed; see: sudo tail -50 /var/log/cloud-init-output.log, or task part7:vm-down and retry)" >&2; exit 1; }; done

# A fresh VM login may not have the docker group yet
if id -nG | grep -qw docker; then exec ./practice/part7/run.sh "$@"; fi
exec sg docker -c "./practice/part7/run.sh $*"
