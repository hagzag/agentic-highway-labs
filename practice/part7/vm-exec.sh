#!/usr/bin/env bash
# Runs inside the Lima VM (see lima.yaml): run.sh <step> with Go, kubectl-ate and the Python deps on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PART7_IN_VM=1
export SUBSTRATE_DIR="${SUBSTRATE_DIR:-$HOME/substrate}"   # build on the VM's disk, not the mount
export PATH="$HOME/.venv-highway/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
if [[ ! -x "$HOME/.venv-highway/bin/python3" ]]; then
  echo "==> Python deps for call.py (first run only)"
  python3 -m venv "$HOME/.venv-highway"
  "$HOME/.venv-highway/bin/pip" install -q -r src/requirements.txt
fi
# A fresh VM login may not have the docker group yet
if id -nG | grep -qw docker; then exec ./practice/part7/run.sh "$@"; fi
exec sg docker -c "./practice/part7/run.sh $*"
