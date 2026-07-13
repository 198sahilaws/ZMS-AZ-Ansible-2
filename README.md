# ZMS control-repo (Ansible push)

The Ansible control repository for the ZMS Azure estate. It is cloned onto the in-VNet **control node** (provisioned by the Terraform stack in the parent directory) and run in **push mode**: the control node connects out to managed VMs — SSH for Linux, WinRM/HTTPS (5986) for Windows — over private addressing.

The control node authenticates to Azure (dynamic inventory **and** Key Vault) **only via its attached user-assigned Managed Identity**. No service-principal keys or secret material ever land on disk; only *names* (vault URL, secret name, subscription, resource group, client id) are injected via `/etc/ansible/estate.env`.

## Layout

```
ansible.cfg                # inventory path, roles/collections, become (linux), forks, logging
requirements.yml           # pinned collections
site.yml                   # estate push: pre-flight + Linux play + Windows play
bootstrap.yml              # control-node self-config: write SSH key from the KV secret
local.yml                  # ansible-pull shim (imports bootstrap.yml)
inventory/azure_rm.yml     # DYNAMIC inventory via azure.azcollection.azure_rm (MSI)
group_vars/
  all.yml                  # KV url + secret name from env; field-scoped lookups
  os_linux.yml             # ssh + become(sudo) + admin user
  os_windows.yml           # winrm 5986, ntlm, cert ignore, creds via KV, become:false
  distro_ubuntu.yml        # ansible_group_priority + apt
  distro_rhel.yml          # ansible_group_priority + dnf
roles/baseline/            # cross-OS baseline (timezone, chrony, base packages)
playbooks/                 # ubuntu-*, rhel-*, windows-* task books
scripts/                   # reconverge.sh, notify-result.sh
systemd/                   # bootstrap + estate service/timer units, estate.env.example
```

## Dynamic inventory

`inventory/azure_rm.yml` uses `azure.azcollection.azure_rm` with `auth_source: msi`. It scopes to the resource group from `AZURE_RESOURCE_GROUP`, includes only VMs tagged **`ManagedBy=Terraform`** (and powered on), sets `ansible_host` to the VM's private IP, and builds groups from tags:

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

- **`os_linux.yml`** — `ansible_connection: ssh`, `ansible_become: true` (sudo), admin user, key at `/etc/ansible/keys/id_ssh`.
- **`os_windows.yml`** — `ansible_connection: winrm`, port `5986`, `ntlm`, `server_cert_validation: ignore`, creds via field-scoped KV lookup, and **`ansible_become: false`** (the global sudo `become` is invalid on Windows; `win_*` tasks run as the admin).
- **`distro_ubuntu.yml` / `distro_rhel.yml`** — `ansible_group_priority: 10` so the distro group wins over `os_linux` on the alphabetical merge; set the package manager (`apt`/`dnf`) and login user.

## Playbooks

`site.yml` runs a pre-flight (assert the vault URL + secret name are set and that the inventory found hosts), then a Linux play and a Windows play, each applying the `baseline` role plus a baseline package, with `serial` for rolling batches and `max_fail_percentage` to bound the blast radius. Packages come only from public/default sources — the distro `apt`/`dnf` repos and the public Chocolatey feed over NAT egress; there is no internal mirror.

Distro-specific playbooks default `hosts` to the matching distro group (`distro_ubuntu` / `distro_rhel`) and keep a `meta: end_host` guard for the wrong OS family. The MySQL playbooks install MariaDB from the distro repos and set the root password idempotently (`plugin: mysql_native_password`, `check_implicit_admin: true`). The Windows playbooks cover forest promotion (`windows-adds`, group `role_dc`), domain join (skipping DCs), IIS, Python (public Chocolatey), an SMB share (parameterised principal, default `Authenticated Users` — never `Everyone`), and the ZMS enforcer (nonce from the `provision_key` secret field).

## Bootstrap & reconverge

`bootstrap.yml` (control-node self-config) asserts the secret name is present and writes the SSH private key from Key Vault to `/etc/ansible/keys/id_ssh`, **owned by and readable by the `ansible` service user** (the timers run as that user, so it is not root-only). Collections are installed beforehand by `scripts/reconverge.sh` via the `ansible-galaxy` CLI — deliberately not via a collection, so bootstrap has no chicken-and-egg dependency.

`scripts/reconverge.sh` sources `/etc/ansible/estate.env` (so manual runs match the unit), `git pull --ff-only`, refreshes collections, then runs `bootstrap.yml`. `scripts/notify-result.sh` logs each run to `/var/log/ansible/converge-status.log` (failures also to `converge-failures.log`) and can POST a failure event to an Event Grid topic if `ALERT_EVENTGRID_TOPIC_URL`/`ALERT_EVENTGRID_KEY` are set — region/target come from env, nothing hardcoded.

## systemd timers

Two `oneshot` services + timers, both running as the `ansible` user with `EnvironmentFile=/etc/ansible/estate.env` and `ExecStopPost` calling `notify-result.sh`:

- `ansible-bootstrap.{service,timer}` — self-converge (`reconverge.sh` → `bootstrap.yml`) ~every 30 min.
- `ansible-estate.{service,timer}` — estate push (`site.yml`) ~every 60 min.

Install on the control node:

```bash
sudo cp systemd/ansible-*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ansible-bootstrap.timer ansible-estate.timer
```

Terraform cloud-init does this automatically when the repo ships the `systemd/` directory.

## Running manually

```bash
# On the control node (env already present):
source /etc/ansible/estate.env
ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph            # confirm discovery
ansible-playbook bootstrap.yml       # write the SSH key from Key Vault
ansible-playbook site.yml            # push the estate

# Target a slice:
ansible-playbook playbooks/ubuntu-apache2.yml
ansible-playbook playbooks/windows-iis.yml -e target_hosts=role_web
```

## Linting

```bash
yamllint -c .yamllint .
ansible-lint
```

`requirements.yml` collections must be installed for `ansible-lint`'s full module resolution; the committed `.ansible-lint` mocks the external modules so the rules can also run offline in CI.
