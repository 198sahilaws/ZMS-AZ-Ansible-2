# ZMS control-repo (Ansible push)

The Ansible control repository for the ZMS Azure estate. It is cloned onto the in-VNet **control node** (provisioned by the Terraform stack in the parent directory) and run in **push mode**: the control node connects out to managed VMs — SSH for Linux, WinRM/HTTPS (5986) for Windows — over private addressing.

The control node authenticates to Azure (dynamic inventory **and** Key Vault) **only via its attached user-assigned Managed Identity**. No service-principal keys or secret material ever land on disk; only *names* (vault URL, secret name, subscription, resource group, client id) are injected via `/etc/ansible/estate.env`.

Runtime: **ansible-core 2.21** (installed as `ansible==14.1.0` by cloud-init) with `pywinrm` in the venv for WinRM. Collections are pinned in `requirements.yml` to the set that ships with that release (plus `ansible.mariadb` for MariaDB).

## Layout

```
ansible.cfg                # inventory path, roles/collections, become (linux), forks, logging
requirements.yml           # pinned collections (incl. ansible.mariadb, not community.mysql)
site.yml                   # baseline push: pre-flight + Linux play + Windows play
orchestrate.yml            # FULL estate, in order: baseline -> Linux roles -> Windows AD chain
linux.yml                  # root entrypoint for just the Linux role chain (no Windows)
bootstrap.yml              # control-node self-config: write SSH key from the KV secret
local.yml                  # ansible-pull shim (imports bootstrap.yml)
inventory/
  azure_rm.yml             # DYNAMIC inventory via azure.azcollection.azure_rm (MSI)
  group_vars/              # loaded next to the inventory so ALL playbooks pick them up
    all.yml                # KV url + secret name from env; field-scoped lookups
    os_linux.yml           # ssh + become(sudo) + admin user + key path
    os_windows.yml         # winrm 5986, ntlm, cert ignore, creds via KV, become:false
    distro_ubuntu.yml      # ansible_group_priority + apt
    distro_rhel.yml        # ansible_group_priority + dnf
roles/baseline/            # cross-OS baseline (timezone, chrony, base packages)
playbooks/                 # 17 role playbooks: ubuntu-*, rhel-*, linux-*, windows-*
scripts/                   # reconverge.sh, notify-result.sh, collect-debug.sh
systemd/                   # bootstrap + estate service/timer units, estate.env.example
```

> **group_vars location matters.** Ansible loads `group_vars/` relative to the *inventory* directory or the *top-level playbook* directory. Because these live at `inventory/group_vars/`, they apply to every play — including the ones under `playbooks/` that `orchestrate.yml` imports. Always launch from a **root-level entrypoint** (`site.yml`, `orchestrate.yml`, `linux.yml`); running a `playbooks/*.yml` file directly skips the connection vars and SSH falls back to the wrong user.

## Dynamic inventory

`inventory/azure_rm.yml` uses `azure.azcollection.azure_rm` with `auth_source: msi`. It scopes to the resource group via the **`ANSIBLE_AZURE_VM_RESOURCE_GROUPS`** environment variable (the plugin reads that directly; a `{{ lookup('env', ...) }}` in `include_vm_resource_groups` does *not* resolve for that option). It keeps only VMs tagged **`ManagedBy=Terraform`** and powered on, **excludes the control node** (`Role=ansible-control`), sets `ansible_host` to the private IP, and builds groups from tags:

| Tag | Group prefix | Example |
|---|---|---|
| `OS` | `os_` | `os_linux`, `os_windows` |
| `Distro` | `distro_` | `distro_ubuntu`, `distro_rhel` |
| `Role` | `role_` | `role_web`, `role_dc` |
| `Environment` | `env_` | `env_dev` |

A `domain_controllers` convenience group is built from `Domain_Controller=Enabled`.

## Secrets — field-scoped, never a global bundle

`group_vars/all.yml` reads only the **secret name + vault URL** from the environment; it never binds the whole secret to a variable. Each consumer resolves the one field it needs, inline, at point of use, with `no_log: true`. For example, Windows auth:

```yaml
ansible_password: >-
  {{ (lookup('azure.azcollection.azure_keyvault_secret',
      ansible_secret_name, vault_url=azure_keyvault_url)
     | from_json).winrm_password }}
```

This keeps the SSH key and passwords out of any global scope, so a stray `-vvv`/`debug` cannot leak them.

## Connection group_vars

- **`os_linux.yml`** — `ansible_connection: ssh`, `ansible_become: true` (sudo), admin user `azureuser`, key at `/etc/ansible/keys/id_ssh`.
- **`os_windows.yml`** — `ansible_connection: winrm`, port `5986`, `ntlm`, `server_cert_validation: ignore`, creds via field-scoped KV lookup, and **`ansible_become: false`** (the global sudo `become` is invalid on Windows; `win_*` tasks run as the admin).
- **`distro_ubuntu.yml` / `distro_rhel.yml`** — `ansible_group_priority: 10` so the distro group wins over `os_linux` on the merge; set the package manager (`apt`/`dnf`) and login user.

## Playbooks

`site.yml` runs a pre-flight (assert the vault URL + secret name are set and the inventory found hosts), then a Linux and a Windows play, each applying the `baseline` role plus a baseline package, with `serial` for rolling batches and `max_fail_percentage` to bound the blast radius. `orchestrate.yml` imports `site.yml` first, then the **Linux role chain**, then the **Windows AD chain** — Linux before Windows so a Windows/WinRM hiccup can't block the (independent) Linux installs.

All role playbooks use a **literal `hosts:`** (e.g. `distro_rhel:&role_db`); scope a manual run with `--limit`, not the old `target_hosts` var. Each keeps a `meta: end_host` guard for the wrong OS family. Highlights:

- **Linux base** (`rhel-setup`, `ubuntu-setup`) — base tooling. `rhel-setup` first enables **EPEL** (for `htop` etc., which aren't in RHEL base/AppStream).
- **Databases** (`rhel-mysql`, `ubuntu-mysql`) — install MariaDB from the distro repos and set the root password idempotently with **`ansible.mariadb.mariadb_user`** (`plugin: mysql_native_password`, `check_implicit_admin: true`).
- **Web** (`rhel-httpd`, `ubuntu-apache2`) and **file share** (`linux-fileshare`, Samba) and **client** (`linux-client`).
- **Windows** — forest promotion (`windows-adds`, group `role_dc`), DNS (`windows-dns`), domain join (`windows-domain-join`, skipping DCs), RODC (`windows-rodc`), IIS, an SMB share (parameterised principal, default `Authenticated Users` — never `Everyone`), Python (public Chocolatey), the ZMS enforcer (nonce from the `provision_key` secret field), and `windows-client`.

Packages come only from public/default sources — distro `apt`/`dnf` repos, EPEL, and the public Chocolatey feed over NAT egress; there is no internal mirror.

## Bootstrap & reconverge

`bootstrap.yml` (control-node self-config) asserts the secret name is present and writes the SSH private key from Key Vault to `/etc/ansible/keys/id_ssh`, **owned by and readable by the `ansible` service user** (the timers run as that user). The localhost plays run with `become: false` (the `ansible` user has no passwordless sudo; cloud-init pre-creates the needed dirs).

`scripts/reconverge.sh` sources `/etc/ansible/estate.env`, `git pull --ff-only`, refreshes collections with `ansible-galaxy collection install -r requirements.yml --upgrade` (so changed pins actually replace an installed version), then runs `bootstrap.yml`. `scripts/notify-result.sh` logs each run to `/var/log/ansible/converge-status.log` (failures also to `converge-failures.log`) and can POST a failure event to Event Grid if `ALERT_EVENTGRID_TOPIC_URL`/`ALERT_EVENTGRID_KEY` are set. `scripts/collect-debug.sh` gathers a redacted diagnostics bundle.

## systemd timers

Two `oneshot` services + timers, both running as the `ansible` user with `EnvironmentFile=/etc/ansible/estate.env` and `ExecStopPost` calling `notify-result.sh`:

- `ansible-bootstrap.{service,timer}` — self-converge (`reconverge.sh` → `bootstrap.yml`) ~every 30 min.
- `ansible-estate.{service,timer}` — **full estate push (`orchestrate.yml`)** ~every 60 min (`TimeoutStartSec=7200` to allow DC promotion + reboots).

Cloud-init copies these into `/etc/systemd/system/` and enables them on first boot, so the estate converges automatically. To update them on an already-running node (reconverge's `git pull` does **not** re-copy units):

```bash
sudo cp systemd/ansible-*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ansible-bootstrap.timer ansible-estate.timer
```

## Running manually

Always run from the repo root so `inventory/group_vars/` loads:

```bash
# On the control node:
set -a; . /etc/ansible/estate.env; set +a
cd /opt/control-repo
ansible-galaxy collection install -r requirements.yml --upgrade
ansible-inventory --graph                 # confirm discovery
ansible-playbook bootstrap.yml            # write the SSH key from Key Vault
ansible-playbook orchestrate.yml          # converge the WHOLE estate
# or just the Linux role chain:
ansible-playbook linux.yml

# Target a slice with --limit (the old '-e target_hosts=' override was removed):
ansible-playbook orchestrate.yml --limit role_web
```

## Linting

```bash
yamllint -c .yamllint .
ansible-lint
```

`requirements.yml` collections must be installed for `ansible-lint`'s full module resolution; the committed `.ansible-lint` mocks the external modules (incl. `ansible.mariadb.mariadb_user`) so the rules also run offline in CI.
