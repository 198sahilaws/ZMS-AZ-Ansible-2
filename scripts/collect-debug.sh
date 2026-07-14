#!/usr/bin/env bash
#
# collect-debug.sh - Gather Ansible failure diagnostics from the ZMS control node.
#
# Produces a timestamped tarball under /tmp containing cloud-init logs, the
# Ansible/venv/collection state, config, dynamic-inventory + connectivity checks,
# Managed-Identity/DNS/egress probes, SSH-key metadata, the estate logs, and the
# systemd unit status/journals.
#
# Usage:
#   ./collect-debug.sh              # collect what the current user can read
#   sudo ./collect-debug.sh         # also capture root-owned logs/keys/journals
#
# SECURITY: the bundle may contain identifiers (subscription/RG/vault URL, host
# names, IPs) but deliberately avoids secrets - it never prints the SSH private
# key or the consolidated Key Vault secret, only captures IMDS token HTTP status
# (not the token), never runs a playbook or `ansible-inventory --list` (which
# would resolve credential lookups), and runs a final redaction pass. Still,
# review the tarball before sharing it externally.

set -o pipefail

# ---------------------------------------------------------------- config -----
REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"
VENV="/opt/ansible-venv"
ENV_FILE="/etc/ansible/estate.env"
LOG_DIR="/var/log/ansible"
KEY_FILE="/etc/ansible/keys/id_ssh"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUT_DIR="/tmp/ansible-debug-${HOST}-${TS}"
REPORT="${OUT_DIR}/report.txt"
mkdir -p "$OUT_DIR"

# Resolve ansible* even if the /usr/local/bin symlinks are missing; disable the
# shared log so collection stays read-only and avoids the not-writeable warning.
export PATH="${VENV}/bin:/usr/local/bin:${PATH}"
export ANSIBLE_LOG_PATH="${OUT_DIR}/ansible-collect.log"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE" 2>/dev/null || true; set +a; }

# --------------------------------------------------------------- helpers -----
section() { printf '\n\n========== %s ==========\n' "$*" >>"$REPORT"; }
run() {   # run <label> <cmd...>
  local label="$1"; shift
  printf '\n$ %s\n' "$label" >>"$REPORT"
  timeout 60 "$@" >>"$REPORT" 2>&1 || printf '[exit %s / not available]\n' "$?" >>"$REPORT"
}
runsh() { # runsh <label> <shell string>
  local label="$1"; shift
  printf '\n$ %s\n' "$label" >>"$REPORT"
  timeout 120 bash -lc "$*" >>"$REPORT" 2>&1 || printf '[exit %s / not available]\n' "$?" >>"$REPORT"
}
copy() {  # copy <src> [destname]
  local src="$1"; local dst="${2:-$(basename "$1")}"
  if [ -r "$src" ]; then
    cp -a "$src" "${OUT_DIR}/${dst}" 2>/dev/null \
      && printf '  collected: %s\n' "$src" >>"$REPORT" \
      || printf '  could not copy: %s\n' "$src" >>"$REPORT"
  else
    printf '  not readable (try sudo): %s\n' "$src" >>"$REPORT"
  fi
}

{
  echo "ZMS control-node Ansible debug bundle"
  echo "generated : $(date -u) (UTC)"
  echo "user      : $(id -un) (uid $(id -u))"
  echo "host      : $(hostname -f 2>/dev/null || hostname)"
  echo "repo_dir  : ${REPO_DIR}"
} >"$REPORT"

# 1) host / OS
section "HOST / OS"
run "uname -a" uname -a
copy /etc/os-release os-release
run "uptime" uptime
runsh "disk usage" "df -h / /var /opt 2>/dev/null"
runsh "memory" "free -h 2>/dev/null"

# 2) cloud-init (first-boot control-node bootstrap)
section "CLOUD-INIT"
run "cloud-init status --long" cloud-init status --long
copy /var/log/cloud-init-output.log cloud-init-output.log
copy /var/log/cloud-init.log cloud-init.log

# 3) Ansible + Python environment
section "ANSIBLE / PYTHON ENVIRONMENT"
runsh "which ansible*" "command -v ansible ansible-playbook ansible-galaxy ansible-inventory 2>&1"
run "ansible --version" ansible --version
runsh "venv pip (ansible/azure pkgs)" "${VENV}/bin/pip list 2>/dev/null | grep -Ei 'ansible|azure|msrest|msal|resolvelib|cryptography' || echo 'venv pip not available'"
runsh "installed collections" "ansible-galaxy collection list 2>&1"
# Directly diagnose the azure_rm 'azure_cloud is not defined' root cause:
printf '\n$ azure SDK import check\n' >>"$REPORT"
timeout 30 "${VENV}/bin/python" - >>"$REPORT" 2>&1 <<'PY' || printf '[python not available]\n' >>"$REPORT"
mods = ['azure.identity', 'azure.mgmt.compute', 'azure.mgmt.network',
        'azure.mgmt.resource', 'msrestazure', 'azure.keyvault.secrets']
for m in mods:
    try:
        __import__(m)
        print('ok  ', m)
    except Exception as e:
        print('FAIL', m, '->', repr(e))
PY

# 4) configuration
section "CONFIGURATION"
copy "${REPO_DIR}/ansible.cfg" ansible.cfg
copy "${REPO_DIR}/inventory/azure_rm.yml" azure_rm.yml
runsh "effective config (changed only)" "cd '${REPO_DIR}' && ansible-config dump --only-changed 2>&1 | head -n 80"
if [ -r "$ENV_FILE" ]; then
  printf '\n--- %s (names only; no secrets by design) ---\n' "$ENV_FILE" >>"$REPORT"
  cat "$ENV_FILE" >>"$REPORT" 2>/dev/null
  cp -a "$ENV_FILE" "${OUT_DIR}/estate.env" 2>/dev/null
else
  printf '\n%s not readable (try sudo)\n' "$ENV_FILE" >>"$REPORT"
fi

# 5) dynamic inventory (structure only - never --list/--vars, they resolve creds)
section "INVENTORY (structure only)"
runsh "ansible-inventory --graph" "cd '${REPO_DIR}' && ansible-inventory --graph 2>&1"

# 6) Azure Managed Identity via IMDS (HTTP status only, never the token)
section "AZURE MANAGED IDENTITY (IMDS)"
runsh "AZURE_CLIENT_ID set?" "[ -n \"\${AZURE_CLIENT_ID:-}\" ] && echo 'AZURE_CLIENT_ID is set' || echo 'AZURE_CLIENT_ID NOT set'"
runsh "IMDS mgmt token (status)" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' -H Metadata:true --max-time 10 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/' || echo 'IMDS unreachable'"
runsh "IMDS vault token (status)" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' -H Metadata:true --max-time 10 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net' || echo 'IMDS unreachable'"

# 7) DNS + egress
section "DNS / NETWORK EGRESS"
copy /etc/resolv.conf resolv.conf
runsh "resolve pypi + vault host" "getent hosts pypi.org; [ -n \"\${AZURE_KEYVAULT_URL:-}\" ] && getent hosts \"\$(printf '%s' \"\$AZURE_KEYVAULT_URL\" | sed -E 's#https?://([^/]+).*#\1#')\""
runsh "egress -> pypi (status)" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 12 https://pypi.org/simple/ || echo 'no egress'"
runsh "egress -> key vault (status)" "[ -n \"\${AZURE_KEYVAULT_URL:-}\" ] && curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 12 \"\$AZURE_KEYVAULT_URL\" || echo 'AZURE_KEYVAULT_URL unset'"

# 8) SSH key (metadata only, never the contents)
section "SSH KEY (metadata only)"
runsh "key file perms" "ls -l '${KEY_FILE}' 2>&1 || echo 'key file missing (bootstrap.yml not run?)'"
runsh "key fingerprint" "ssh-keygen -lf '${KEY_FILE}' 2>&1 || echo 'cannot read fingerprint'"

# 9) estate logs
section "ANSIBLE LOGS"
copy "${LOG_DIR}/ansible.log" ansible.log
copy "${LOG_DIR}/converge-status.log" converge-status.log
copy "${LOG_DIR}/converge-failures.log" converge-failures.log
runsh "recent failures in ansible.log" "tail -n 600 '${LOG_DIR}/ansible.log' 2>/dev/null | grep -iE 'fatal|failed=|unreachable|error|traceback' | tail -n 120 || echo 'no ansible.log (try sudo)'"

# 10) systemd units + journals
section "SYSTEMD (timers + services)"
run "list-timers" systemctl list-timers "ansible-*" --all --no-pager
for u in ansible-bootstrap ansible-estate; do
  run "status ${u}.service" systemctl status "${u}.service" --no-pager -l
  runsh "journal ${u} (last 200)" "journalctl -u ${u}.service -n 200 --no-pager 2>&1 || echo 'no journal access (try sudo)'"
done

# 11) control repo state + syntax check
section "CONTROL REPO"
runsh "git log/status" "cd '${REPO_DIR}' && git -c safe.directory='${REPO_DIR}' log --oneline -n 5 2>&1; echo '---'; git -c safe.directory='${REPO_DIR}' status -s 2>&1"
runsh "site.yml --syntax-check" "cd '${REPO_DIR}' && ansible-playbook site.yml --syntax-check 2>&1 | tail -n 40"
runsh "orchestrate.yml --syntax-check" "cd '${REPO_DIR}' && ansible-playbook orchestrate.yml --syntax-check 2>&1 | tail -n 40"

# 12) live reachability (default verbosity; credentials are NOT printed)
section "CONNECTIVITY PROBE (best-effort)"
runsh "ping Linux (SSH)" "cd '${REPO_DIR}' && timeout 90 ansible os_linux -m ansible.builtin.ping -o 2>&1 | tail -n 50 || echo 'skipped/failed'"
runsh "ping Windows (WinRM)" "cd '${REPO_DIR}' && timeout 120 ansible os_windows -m ansible.windows.win_ping -o 2>&1 | tail -n 50 || echo 'skipped/failed'"

# ----------------------------------------------- redact + package (safety) ---
# Defense in depth: scrub anything that looks like a token/password value.
find "$OUT_DIR" -type f -print0 2>/dev/null | xargs -0 -r sed -i -E \
  -e 's/(access_token"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
  -e 's/(Bearer )[A-Za-z0-9._+/=-]+/\1<REDACTED>/g' \
  -e 's/([Pp]assword"?[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+/\1<REDACTED>/g' \
  2>/dev/null || true

TARBALL="/tmp/ansible-debug-${HOST}-${TS}.tar.gz"
tar -czf "$TARBALL" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" 2>/dev/null

echo
echo "Ansible debug bundle written:"
echo "  folder : $OUT_DIR"
echo "  tarball: $TARBALL"
echo
echo "Copy it off the node, e.g. from your workstation:"
echo "  scp -i <key>.pem -o ProxyJump=azureuser@<bastion-ip> ansible@$(hostname -s):$TARBALL ."
echo
echo "Review before sharing (contains subscription/RG/vault identifiers)."
echo "Re-run with sudo to include root-owned logs, keys, and journals."
