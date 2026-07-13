#!/usr/bin/env bash
# Refresh the control repo + collections and self-converge (bootstrap.yml).
# Sources estate.env first so manual runs behave exactly like the systemd
# unit (which also loads it via EnvironmentFile).
set -euo pipefail

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
ansible-galaxy collection install -r requirements.yml

exec ansible-playbook bootstrap.yml
