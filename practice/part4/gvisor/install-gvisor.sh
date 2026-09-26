#!/usr/bin/env bash
# Best-effort gVisor install for a k3d cluster. Runs on the HOST (needs docker + k3d).
# Downloads runsc + the containerd shim on the host (the k3s node image has no curl and
# a busybox wget that can't fetch these), copies them into each k3s node container,
# drops in a containerd runtime handler, and restarts k3s.
#
# gVisor is the one piece of Part 4 that depends on your machine (nested virt, arch,
# Docker runtime). If this fails, the rest of the lab still runs on runc; the fence is
# carried by NetworkPolicy + no token, not by gVisor.
set -euo pipefail
CLUSTER="${CLUSTER:-highway}"
CHANNEL="${GVISOR_CHANNEL:-release/latest}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -m)" in
  arm64|aarch64) ARCH=aarch64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
BASE="https://storage.googleapis.com/gvisor/releases/${CHANNEL}/${ARCH}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "==> downloading gVisor ($ARCH, $CHANNEL) on the host"
# The release channel ships individual binaries; fall back to the tarball if that 404s.
if curl -fsSL "${BASE}/runsc" -o "$tmp/runsc" 2>/dev/null \
   && curl -fsSL "${BASE}/containerd-shim-runsc-v1" -o "$tmp/containerd-shim-runsc-v1" 2>/dev/null; then
  chmod 0755 "$tmp/runsc" "$tmp/containerd-shim-runsc-v1"
else
  echo "   individual binaries not found; trying gvisor.tar.zst"
  curl -fsSL "${BASE}/gvisor.tar.zst" -o "$tmp/gvisor.tar.zst"
  ( cd "$tmp" && tar --use-compress-program=unzstd -xf gvisor.tar.zst 2>/dev/null \
      || zstd -d gvisor.tar.zst -o gvisor.tar && tar -xf gvisor.tar )
  find "$tmp" -name runsc -exec cp {} "$tmp/runsc" \; 2>/dev/null || true
  find "$tmp" -name containerd-shim-runsc-v1 -exec cp {} "$tmp/containerd-shim-runsc-v1" \; 2>/dev/null || true
  chmod 0755 "$tmp/runsc" "$tmp/containerd-shim-runsc-v1" 2>/dev/null || true
fi
[ -x "$tmp/runsc" ] || { echo "could not obtain runsc for $ARCH; skipping gVisor"; exit 1; }
"$tmp/runsc" --version 2>/dev/null | head -1 || true

nodes="$(k3d node list -o json | grep -o "\"name\":\"k3d-${CLUSTER}-\(server\|agent\)[^\"]*\"" | cut -d'"' -f4)"
[ -n "$nodes" ] || { echo "no k3d nodes for cluster '$CLUSTER'"; exit 1; }

for n in $nodes; do
  echo "==> $n: installing runsc + containerd handler"
  docker cp "$tmp/runsc"                       "$n:/usr/local/bin/runsc"
  docker cp "$tmp/containerd-shim-runsc-v1"    "$n:/usr/local/bin/containerd-shim-runsc-v1"
  docker exec "$n" chmod 0755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1
  docker exec "$n" mkdir -p /var/lib/rancher/k3s/agent/etc/containerd /etc/containerd
  docker cp "$HERE/config-v3.toml.tmpl" "$n:/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl"
  docker cp "$HERE/config.toml.tmpl"    "$n:/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
  docker cp "$HERE/runsc.toml"          "$n:/etc/containerd/runsc.toml"
  echo "==> $n: restarting to load the runsc handler"
  docker restart "$n" >/dev/null
done

echo "==> waiting for the cluster to come back"
for _ in $(seq 60); do kubectl get nodes >/dev/null 2>&1 && break; sleep 2; done
kubectl -n kube-system rollout status ds -l k8s-app --timeout=120s >/dev/null 2>&1 || true
echo "gVisor install attempted on: $(echo "$nodes" | tr '\n' ' ')"
EOF
