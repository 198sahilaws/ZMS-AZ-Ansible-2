#!/usr/bin/env bash
# Refresh the control repo + collections and self-converge (bootstrap.yml).
# Sources estate.env first so manual runs behave exactly like the systemd
# unit (which also loads it via EnvironmentFile).
set -euo pipefail

# Ensure the venv Ansible binaries are on PATH (independent of symlinks).
export PATH="/opt/ansible-venv/bin:$PATH"

ENV_FILE=/etc/ansible/estate.env
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"
cd "$REPO_DIR"

# Fast-forward only; never rewrite local history on the control node.
git pull --ff-only || echo "reconverge: git pull skipped/failed; using local repo"

# Install/refresh the pinned collections via the CLI (not via a collection).
# --upgrade so changed pins (e.g. azure.azcollection 3.1.0 -> 3.19.0) actually
# replace an already-installed version instead of being skipped as present.
ansible-galaxy collection install -r requirements.yml --upgrade

exec ansible-playbook bootstrap.yml
