#!/usr/bin/env bash
# Runs inside the Lima VM (see lima.yaml): run.sh <step> with Go and kubectl-ate on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PART7_IN_VM=1
export SUBSTRATE_DIR="${SUBSTRATE_DIR:-$HOME/substrate}"   # build on the VM's disk, not the mount
# Some hosts (index.crates.io) are unreachable from Docker's bridge network in a Lima VM on a
# managed Mac, while the VM itself reaches them. Substrate's ate-setup reads DOCKER_BUILD_FLAGS
# for the images it builds with docker (the Envoy dataplane runs cargo), and run.sh uses it for the
# highway image (pip), so every image builds on the host network.
export DOCKER_BUILD_FLAGS="${DOCKER_BUILD_FLAGS:---network=host}"
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# DNS: on a managed Mac the VM's own resolvers (Lima's 192.168.5.x and the vzNAT gateway) can
# time out while public resolvers answer. Pin the VM and Docker (builds, containers, kind nodes)
# to 1.1.1.1 / 8.8.8.8. Override with PART7_DNS="a b".
DNS="${PART7_DNS:-1.1.1.1 8.8.8.8}"
if ! grep -qs "DNS=$DNS" /etc/systemd/resolved.conf.d/10-part7.conf; then
  echo "==> Pinning DNS to $DNS in the VM and Docker"
  sudo mkdir -p /etc/systemd/resolved.conf.d /etc/docker
  printf '[Resolve]\nDNS=%s\nDomains=~.\n' "$DNS" | sudo tee /etc/systemd/resolved.conf.d/10-part7.conf >/dev/null
  sudo systemctl restart systemd-resolved
  python3 -c 'import json,sys; print(json.dumps({"dns": sys.argv[1:]}))' $DNS | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
fi

# Outbound network check. Lima's user-mode network may hand out IPv6 answers it can't route:
# if IPv4 works and the default doesn't, prefer IPv4 for good.
net() { curl -fsS -o /dev/null -m 10 "$@" https://pypi.org/simple/pip/; }   # small page, not the full index
if ! net; then
  if net -4; then
    echo "==> IPv6 is unreachable in the VM; preferring IPv4"
    grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null ||
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

# Substrate's setup builds images with `docker build --platform`, which needs buildx
docker buildx version >/dev/null 2>&1 || sudo docker buildx version >/dev/null 2>&1 || {
  echo "==> Installing docker-buildx"; sudo apt-get install -y -qq docker-buildx >/dev/null; }

# A fresh VM login may not have the docker group yet
if id -nG | grep -qw docker; then exec bash ./practice/part7/run.sh "$@"; fi
exec sg docker -c "bash ./practice/part7/run.sh $*"
