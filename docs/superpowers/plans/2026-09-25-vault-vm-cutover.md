# Vault VM Rebuild, Cutover and Decommission Implementation Plan (PRs 3-5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the empty `vault-02` VM into the Vault every consumer uses — Raft on its own disk, TLS from a workstation-held CA, audit log, `kv-dev/`/`kv-prod/` mounts with per-cluster policies, daily snapshots to `nfs-01` — then move ArgoCD onto it and destroy the `vault-01` LXC.

**Architecture:** PR 3 rebuilds `ansible/roles/vault` around `vault-02` and adds a `coredns_hosts` role that pins `vault.mgryn.cc` inside the cluster; the old LXC keeps serving throughout. PR 4 points AVP at `https://vault.mgryn.cc:8200` with the CA mounted from a `vault-ca` ConfigMap, and moves the five placeholders to `kv-dev/`. PR 5 deletes every trace of the LXC, including prod's never-applied duplicate.

**Tech Stack:** Ansible core 2.21 (ansible-lint production profile), `community.crypto` 3.4.0, `ansible.posix`, `community.general`, `kubernetes.core`; HashiCorp Vault 2.1.0 (apt `2.1.0-1`); Terraform 1.16 + `telmate/proxmox` 3.0.2-rc10; kustomize.

**Spec:** `docs/superpowers/specs/2026-09-25-vault-vm-design.md` — sections "PR 3", "PR 4", "PR 5", "Documentation", "Verification".

**Prior plan:** `docs/superpowers/plans/2026-09-25-vault-vm-infra.md` (PRs 1-2, merged and applied). What exists now: `vault-02` (vmid 105, `10.0.0.133`, data disk `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1`, empty, no filesystem, `nfs-common` installed by hand); group `vault_vm` in `ansible/inventories/shared/hosts.yaml`; `/srv/nfs/backups` on `nfs-01` (`10.0.0.131`), mode 0700, exported to `10.0.0.133` only.

## Global Constraints

- Three branches, one per PR, each cut from `main` after the previous PR merges: `vault-role-rebuild` (PR 3, exists), `vault-cutover` (PR 4), `vault-lxc-decommission` (PR 5). Never commit to `main`, never merge, never push to `main`. An agent's job ends at an open PR.
- PRs 4 and 5 land the same day. PR 4 starts only after PR 3 is merged **and** its operator task has passed.
- Commits: Conventional Commits, subject ≤ 50 chars, imperative, lowercase, no trailing period, body wrapped at 72. Types: `feat fix refactor docs chore ops`.
- **No `Co-Authored-By` trailer and no "generated with" line** in commits or PR bodies. CLAUDE.md overrides any default attribution.
- `vault-02`: `10.0.0.133`, node id `vault-02`, API `8200`, cluster `8201`. Name `vault.mgryn.cc`, used by every consumer. Consumers reach `https://vault.mgryn.cc:8200`.
- Storage: integrated Raft at `/var/lib/vault/raft` on the data disk mounted at `/var/lib/vault` by label `vault-data`. `disable_mlock = true`. No LXC capability drop-in.
- TLS: CA key and cert at `vault_ca_dir` (default `~/.homelab-ca/`) **on the workstation only**; CA validity 10 years (3650 days); server cert 825 days, SANs `IP:10.0.0.133`, `DNS:vault-02`, `DNS:vault.mgryn.cc`; re-running the role reissues a certificate within 30 days of expiry.
- Audit: `file` device at `/var/log/vault/audit.log`, logrotate with `copytruncate`.
- KV: `kv-dev/` and `kv-prod/`, KV v2. Policy per cluster, `<kv_mount>/data/*` read and `<kv_mount>/metadata/*` list+read, **no wildcard spanning mounts**. Seeding writes `vault_kv` into `vault_kv_mount` (default `kv-dev`); `secret.yaml` keys stay unprefixed.
- Snapshots: AppRole whose policy grants only `sys/storage/raft/snapshot`; credentials in `/etc/vault.d/snapshot.env`, mode 0600; `/mnt/vault-backups` from `10.0.0.131:/srv/nfs/backups` with `nofail,_netdev`; a daily timer; the job asserts the mountpoint and fails loudly; 14 kept.
- `vault operator init` and every unseal stay manual. The role never sees the unseal key; the root token arrives per run as `-e vault_token=...`, never from `secret.yaml` or defaults.
- CoreDNS pin: Ansible owns it (never ArgoCD), a `hosts` block mapping `10.0.0.133 vault.mgryn.cc` in the `coredns` ConfigMap in `kube-system`, then the Deployment is restarted.
- Never run a playbook against a real host, never `terraform plan`/`apply` against Proxmox, never read or decrypt `ansible/secret.yaml`. Local rehearsals run only against `localhost` in `$SCRATCH`.
- Tools: `ansible-lint`, `pre-commit`, `terraform`, `tflint`, `kustomize`, `helm` on PATH; `ansible-playbook`/`ansible-inventory`/`ansible-galaxy` at `/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/` (pipe output through `| cat`, Ansible refuses non-blocking stdio). `community.crypto` 3.4.0 is installed in `~/.ansible/collections`. `SCRATCH=/tmp/claude-1000/-home-ubuntu-homelab/8853d54e-3c7d-4293-bbe1-b61be8da7a2d/scratchpad`. Tests live in `$SCRATCH`, not in the repo — the repository has no test suite.
- Read narrowly: `grep -n`, `sed -n`, `head`/`tail`.
- Scratch tests that touch the role run as a fake host named `vault-02` on the local connection, with the venv's Python (it has `cryptography`):
  `B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin; ANSIBLE_ROLES_PATH=/home/ubuntu/homelab/ansible/roles $B/ansible-playbook -i vault-02, -c local -e ansible_python_interpreter=$B/python <test>.yaml 2>&1 | cat`
  — written below as `RUN <test>.yaml`. Plays in these tests say `hosts: all`.

## File Map

| File | PR | Change | Responsibility |
| --- | --- | --- | --- |
| `ansible/roles/vault/defaults/main.yaml` | 3 | rewrite | Every tunable of the role |
| `ansible/roles/vault/vars/main.yaml` | 3 | create | Keys a cluster entry must carry |
| `ansible/roles/vault/tasks/main.yaml` | 3 | rewrite | Phase wiring |
| `ansible/roles/vault/tasks/validate_clusters.yaml` | 3 | create | Refuse malformed `vault_k8s_clusters` |
| `ansible/roles/vault/tasks/install.yaml` | 3 | trim | Packages and the pinned Vault |
| `ansible/roles/vault/tasks/disk.yaml` | 3 | create | Data disk: filesystem and mount |
| `ansible/roles/vault/tasks/tls.yaml` | 3 | create | CA on the workstation, server cert on the VM |
| `ansible/roles/vault/tasks/config.yaml` | 3 | create | `vault.hcl`, drop-in, logrotate, service |
| `ansible/roles/vault/tasks/snapshot_host.yaml` | 3 | create | NFS mount, script, units |
| `ansible/roles/vault/tasks/{configure,preflight,kv_mounts,audit,snapshot_approle}.yaml` | 3 | create | Token-needing configuration |
| `ansible/roles/vault/tasks/{k8s_auth,k8s_auth_cluster}.yaml` | 3 | rewrite/create | Per-cluster Kubernetes auth |
| `ansible/roles/vault/tasks/seed.yaml` | 3 | modify | Seed into `vault_kv_mount` over HTTPS |
| `ansible/roles/vault/templates/{vault.hcl,k8s-policy.hcl,snapshot.env,logrotate-audit}.j2` | 3 | create/rewrite | Rendered files |
| `ansible/roles/vault/files/{vault-snapshot.sh,vault-snapshot.service,vault-snapshot.timer}` | 3 | create | The snapshot job |
| `ansible/roles/vault/handlers/main.yaml` | 3 | rewrite | Restart, reload, trust store |
| `ansible/roles/coredns_hosts/**`, `ansible/playbooks/coredns_hosts.yaml` | 3 | create | The in-cluster name pin |
| `ansible/playbooks/vault.yaml`, `ansible/requirements.yml`, `ansible/secret.yaml.example` | 3 | modify | Target, collection, example keys |
| `CLAUDE.md`, `docs/rebuild.md`, `ansible/README.md` | 3, 4, 5 | modify | Documentation |
| `ansible/roles/argocd/{defaults,tasks}/main.yaml` | 4 | modify | AVP over HTTPS by name, CA ConfigMap |
| `argocd/apps/jobboard/{base,dev}/*`, `argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml` | 4 | modify/move | Placeholders on `kv-dev/` |
| `terraform/environments/{dev,prod}/*`, `ansible/inventories/{dev,prod,shared}/hosts.yaml` | 5 | modify | The LXC and prod's duplicate removed |

**PR boundaries:** Tasks 1-9 are PR 3, Task 10 its operator run. Tasks 11-13 are PR 4, Task 14 its operator run. Tasks 15-17 are PR 5, Task 18 its operator run.

---

## PR 3 — the new Vault, built and configured

### Task 1: Role defaults and cluster validation

**Files:**
- Rewrite: `ansible/roles/vault/defaults/main.yaml`
- Create: `ansible/roles/vault/vars/main.yaml`, `ansible/roles/vault/tasks/validate_clusters.yaml`
- Test (scratch): `$SCRATCH/vault-tests/validate-clusters-test.yaml`

**Interfaces:**
- Produces every variable later tasks consume: `vault_version, vault_data_device, vault_data_mount, vault_data_dir, vault_config_dir, vault_tls_dir, vault_listen_address, vault_api_port, vault_cluster_port, vault_address, vault_api_url, vault_ca_dir, vault_ca_common_name, vault_ca_validity_days, vault_cert_validity_days, vault_cert_renew_within_days, vault_tls_dns_names, vault_tls_group, vault_tls_trust_system, vault_audit_log, vault_service_managed, vault_kv_mounts, vault_kv_mount, vault_k8s_clusters, vault_snapshot_src, vault_snapshot_dir, vault_snapshot_keep, vault_snapshot_role, vault_configure, vault_configure_k8s_auth, vault_seed`; role var `vault_k8s_cluster_keys`; tasks file `validate_clusters.yaml`.

- [x] **Step 1: Write the failing test**

Create `$SCRATCH/vault-tests/validate-clusters-test.yaml`:

```yaml
- name: vault_k8s_clusters validation accepts the default and refuses each malformation
  hosts: all
  gather_facts: false
  vars:
    host_ips: {master-01: 10.0.0.101, nfs-01: 10.0.0.131}
    good:
      name: dev
      kv_mount: kv-dev
      auth_path: kubernetes
      api_host: 10.0.0.101
      control_plane_host: master-01
      policy_name: argocd-read
      role_name: argocd
      service_account_names: [argocd-repo-server]
      service_account_namespaces: [argocd]
    cases:
      - {label: missing key, expect_fail: true, clusters: [{name: dev, kv_mount: kv-dev}]}
      - {label: shared auth_path, expect_fail: true, clusters: ["{{ good }}", "{{ good | combine({'name': 'prod', 'kv_mount': 'kv-prod'}) }}"]}
      - {label: shared kv_mount, expect_fail: true, clusters: ["{{ good }}", "{{ good | combine({'name': 'prod', 'auth_path': 'kubernetes-prod'}) }}"]}
      - {label: unknown kv_mount, expect_fail: true, clusters: ["{{ good | combine({'kv_mount': 'kv-staging'}) }}"]}
      - {label: two good clusters, expect_fail: false, clusters: ["{{ good }}", "{{ good | combine({'name': 'prod', 'kv_mount': 'kv-prod', 'auth_path': 'kubernetes-prod'}) }}"]}
  tasks:
    - name: The role default passes
      ansible.builtin.include_role:
        name: vault
        tasks_from: validate_clusters

    - name: Each case
      ansible.builtin.include_tasks: validate-clusters-case.yaml
      loop: "{{ cases }}"
      loop_control:
        loop_var: case
        label: "{{ case.label }}"
```

and `$SCRATCH/vault-tests/validate-clusters-case.yaml`:

```yaml
- name: "Run the validation: {{ case.label }}"
  block:
    - name: Validate
      ansible.builtin.include_role:
        name: vault
        tasks_from: validate_clusters
      vars:
        vault_k8s_clusters: "{{ case.clusters }}"
    - name: Record a pass
      ansible.builtin.set_fact:
        case_failed: false
  rescue:
    - name: Record a failure
      ansible.builtin.set_fact:
        case_failed: true

- name: "Expect {{ 'a refusal' if case.expect_fail else 'a pass' }}: {{ case.label }}"
  ansible.builtin.assert:
    that: case_failed == case.expect_fail
```

- [x] **Step 2: Run it to verify it fails**

```bash
cd $SCRATCH/vault-tests && RUN validate-clusters-test.yaml
```

Expected: FAIL — `validate_clusters.yaml` does not exist.

- [x] **Step 3: Rewrite `defaults/main.yaml`**

Keep the existing `vault_version` comment block verbatim except: `apt-cache madison vault` "on vault-01" becomes "on vault-02", and add one sentence after "It happened to work.": "Raft does not downgrade either." Then:

```yaml
---
# <the vault_version comment block, as above>
vault_version: "2.1.0-1"

# The raft store lives on its own disk (scsi1 in terraform/modules/vault-vm),
# mounted by label. The data directory is a subdirectory of the mount, so
# ext4's lost+found never sits among raft's files.
vault_data_device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
vault_data_mount: /var/lib/vault
vault_data_dir: /var/lib/vault/raft

vault_config_dir: /etc/vault.d
vault_tls_dir: /etc/vault.d/tls
vault_listen_address: "0.0.0.0:8200"
vault_api_port: 8200
vault_cluster_port: 8201
# The address this role talks to and the certificate's IP SAN. From facts,
# not host_ips, so a rehearsal against 127.0.0.1 needs one override.
vault_address: "{{ ansible_facts['default_ipv4']['address'] }}"
vault_api_url: "https://{{ vault_address }}:{{ vault_api_port }}"

# TLS. The CA lives on the workstation that runs Ansible and never reaches
# the Vault host -- only what it signs does. Losing this directory loses no
# data: delete it, re-run the role, and refresh the vault-ca ConfigMap (the
# argocd role) from the new ca.crt.
vault_ca_dir: "~/.homelab-ca"
vault_ca_common_name: homelab Vault CA
vault_ca_validity_days: 3650
vault_cert_validity_days: 825
# A run inside this many days of expiry signs a fresh server certificate.
vault_cert_renew_within_days: 30
vault_tls_dns_names:
  - "{{ inventory_hostname }}"
  - vault.mgryn.cc
vault_tls_group: vault
# Put ca.crt in the host's trust store, so the vault CLI and the snapshot
# job on the host verify the listener without being told where the CA is.
vault_tls_trust_system: true

# If Vault cannot write this file it refuses every request: an unauditable
# request is refused by design. A full root disk therefore looks like a
# healthy Vault that answers nothing.
vault_audit_log: /var/log/vault/audit.log

# False only for a rehearsal against a Vault this role did not start: the
# handlers then leave systemd alone.
vault_service_managed: true

# KV v2, one mount per environment. Only vault_kv_mount is seeded.
vault_kv_mounts:
  - kv-dev
  - kv-prod
vault_kv_mount: kv-dev

# One entry per cluster that reads this Vault. control_plane_host lives in
# inventories/dev, so a run with vault_configure=true needs
# -i inventories/shared -i inventories/dev.
vault_k8s_clusters:
  - name: dev
    kv_mount: kv-dev
    auth_path: kubernetes
    api_host: "{{ host_ips['master-01'] }}"
    control_plane_host: master-01
    policy_name: argocd-read
    role_name: argocd
    service_account_names: ["argocd-repo-server"]
    service_account_namespaces: ["argocd"]

vault_snapshot_src: "{{ host_ips['nfs-01'] }}:/srv/nfs/backups"
vault_snapshot_dir: /mnt/vault-backups
vault_snapshot_keep: 14
vault_snapshot_role: vault-snapshot

# Phases. Install always runs. Configure and seed need an initialised,
# unsealed Vault and -e vault_token=<root token>.
vault_configure: false
vault_configure_k8s_auth: true
vault_seed: false
```

- [x] **Step 4: Create `vars/main.yaml`**

```yaml
---
# Every vault_k8s_clusters entry must carry all of these. Not a default:
# nothing about it is tunable.
vault_k8s_cluster_keys:
  - name
  - kv_mount
  - auth_path
  - api_host
  - control_plane_host
  - policy_name
  - role_name
  - service_account_names
  - service_account_namespaces
```

- [x] **Step 5: Create `tasks/validate_clusters.yaml`**

```yaml
---
- name: Require every cluster entry to carry every key
  ansible.builtin.assert:
    that:
      - vault_k8s_cluster_keys | difference(item.keys() | list) | length == 0
    fail_msg: >-
      vault_k8s_clusters entry {{ item.name | default(ansible_loop.index) }}
      is missing {{ vault_k8s_cluster_keys | difference(item.keys() | list) | join(', ') }}.
    quiet: true
  loop: "{{ vault_k8s_clusters }}"
  loop_control:
    extended: true
    label: "{{ item.name | default(ansible_loop.index) }}"

- name: Refuse two clusters sharing an auth_path
  ansible.builtin.assert:
    that:
      - vault_k8s_clusters | map(attribute='auth_path') | unique | length == vault_k8s_clusters | length
    fail_msg: >-
      Two vault_k8s_clusters entries share an auth_path. The second would
      overwrite the first's kubernetes_host, pointing one cluster's ArgoCD
      at the other's API server.

- name: Refuse two clusters sharing a kv_mount
  ansible.builtin.assert:
    that:
      - vault_k8s_clusters | map(attribute='kv_mount') | unique | length == vault_k8s_clusters | length
    fail_msg: >-
      Two vault_k8s_clusters entries share a kv_mount, so each cluster's
      policy would grant it the other's secrets.

- name: Require every cluster's kv_mount to be one this role creates
  ansible.builtin.assert:
    that:
      - vault_k8s_clusters | map(attribute='kv_mount') | difference(vault_kv_mounts) | length == 0
    fail_msg: >-
      A vault_k8s_clusters kv_mount is not in vault_kv_mounts:
      {{ vault_k8s_clusters | map(attribute='kv_mount') | difference(vault_kv_mounts) | join(', ') }}.
```

- [x] **Step 6: Run the test** — same command as Step 2. Expected: every "Expect" assertion passes, `failed=0` in the recap (rescued failures are counted under `rescued`, not `failed`).

- [x] **Step 7: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/vault 2>&1 | tail -1 | cat
cd .. && git add ansible/roles/vault/defaults ansible/roles/vault/vars ansible/roles/vault/tasks/validate_clusters.yaml
git commit -m "feat: add vault role defaults for the vault vm" -m "Every tunable of the rebuilt role, and a validation that refuses a
vault_k8s_clusters entry missing a key, sharing an auth_path or a
kv_mount, or naming a mount the role does not create."
```

Expected: ansible-lint `Passed`. `main.yaml` is not rewired yet; the role still runs its old tasks until Task 5.

---

### Task 2: Data disk, install and configuration

**Files:**
- Create: `ansible/roles/vault/tasks/disk.yaml`, `ansible/roles/vault/tasks/config.yaml`, `ansible/roles/vault/templates/logrotate-audit.j2`
- Modify: `ansible/roles/vault/tasks/install.yaml`, `ansible/roles/vault/templates/vault.hcl.j2`, `ansible/roles/vault/handlers/main.yaml`
- Test (scratch): `$SCRATCH/vault-tests/config-render-test.yaml`

**Interfaces:**
- Consumes: Task 1 defaults.
- Produces: tasks files `install.yaml`, `disk.yaml`, `config.yaml`; handlers `Restart vault`, `Reload vault`, `Update the CA trust store`; templates `vault.hcl.j2`, `logrotate-audit.j2`.

- [x] **Step 1: Write the failing test**

`$SCRATCH/vault-tests/config-render-test.yaml`:

```yaml
- name: vault.hcl and the audit logrotate render for raft, TLS and the audit log
  hosts: all
  gather_facts: false
  vars_files:
    - /home/ubuntu/homelab/ansible/roles/vault/defaults/main.yaml
  vars:
    vault_address: 10.0.0.133
    host_ips: {master-01: 10.0.0.101, nfs-01: 10.0.0.131}
    hcl: "{{ lookup('ansible.builtin.template', '/home/ubuntu/homelab/ansible/roles/vault/templates/vault.hcl.j2') }}"
    rotate: "{{ lookup('ansible.builtin.template', '/home/ubuntu/homelab/ansible/roles/vault/templates/logrotate-audit.j2') }}"
  tasks:
    - name: Raft on the data directory, named after the host
      ansible.builtin.assert:
        that:
          - "'storage \"raft\"' in hcl"
          - "'path    = \"/var/lib/vault/raft\"' in hcl"
          - "'node_id = \"vault-02\"' in hcl"
          - "'storage \"file\"' not in hcl"
        fail_msg: "{{ hcl }}"
    - name: TLS listener, https api_addr, mlock disabled
      ansible.builtin.assert:
        that:
          - "'tls_cert_file = \"/etc/vault.d/tls/server.crt\"' in hcl"
          - "'tls_key_file  = \"/etc/vault.d/tls/server.key\"' in hcl"
          - "'tls_disable' not in hcl"
          - "'api_addr     = \"https://10.0.0.133:8200\"' in hcl"
          - "'cluster_addr = \"https://10.0.0.133:8201\"' in hcl"
          - "'disable_mlock = true' in hcl"
        fail_msg: "{{ hcl }}"
    - name: The audit log rotates with copytruncate
      ansible.builtin.assert:
        that:
          - "rotate is search('^/var/log/vault/audit.log \\{', multiline=True)"
          - "'copytruncate' in rotate"
        fail_msg: "{{ rotate }}"
```

- [x] **Step 2: Run it to verify it fails**

```bash
cd $SCRATCH/vault-tests && RUN config-render-test.yaml
```

Expected: FAIL — the template still says `storage "file"`, and `logrotate-audit.j2` does not exist.

- [x] **Step 3: Rewrite `templates/vault.hcl.j2`**

```hcl
# Managed by ansible (roles/vault). A change here restarts Vault, and a
# restarted Vault comes back sealed: unseal it by hand after the run.
ui = true

storage "raft" {
  path    = "{{ vault_data_dir }}"
  node_id = "{{ inventory_hostname }}"
}

listener "tcp" {
  address       = "{{ vault_listen_address }}"
  tls_cert_file = "{{ vault_tls_dir }}/server.crt"
  tls_key_file  = "{{ vault_tls_dir }}/server.key"
}

api_addr     = "{{ vault_api_url }}"
cluster_addr = "https://{{ vault_address }}:{{ vault_cluster_port }}"

# HashiCorp's advice for integrated storage: raft's BoltDB file is
# memory-mapped, and locking it into RAM defeats the point.
disable_mlock = true
```

- [x] **Step 4: Create `templates/logrotate-audit.j2`**

```
# Managed by ansible (roles/vault). copytruncate, because Vault keeps the
# audit file open; a rotation that moved it away would leave Vault writing
# to the renamed file.
{{ vault_audit_log }} {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

- [x] **Step 5: Run the test again** — expected: all three assertions pass, `failed=0`.

- [x] **Step 6: Trim `tasks/install.yaml`**

Keep, unchanged: the HashiCorp key download and dearmor, the `deb822_repository` task, `Install Vault` and `Hold Vault at the pinned version`. Delete: the two tasks that find and remove old one-line `.list` files (they existed for `vault-01`'s repository migration; `vault-02` never had one), `Create the Vault directories`, `Render the Vault configuration`, the drop-in directory, `Drop the capability directives the container cannot grant`, and `Enable and start Vault` (these move to `config.yaml`). Replace the prerequisites task with:

```yaml
- name: Install prerequisites
  ansible.builtin.apt:
    name:
      - gpg
      - coreutils
      - python3-debian
      # community.crypto creates the server key and signing request here.
      - python3-cryptography
      # The snapshot job mounts the backups share. The cloud image has no
      # NFS client: vault-02's first mount failed with "bad option".
      - nfs-common
    state: present
    update_cache: true
```

and delete the separate `Install python3-debian for deb822_repository` task.

- [x] **Step 7: Create `tasks/disk.yaml`**

```yaml
---
# Never mount the data disk over a directory that already holds files on the
# root disk -- the mount would hide them. Same guard as roles/nfs_server.
- name: Look for files at the data mount point
  ansible.builtin.find:
    paths: "{{ vault_data_mount }}"
    file_type: any
    hidden: true
  register: vault_data_mount_contents

- name: Refuse to mount the data disk over files on the root disk
  ansible.builtin.assert:
    that:
      - >-
        vault_data_mount_contents.matched == 0 or
        (ansible_facts['mounts'] | selectattr('mount', 'equalto', vault_data_mount) | list | length > 0)
    fail_msg: >-
      {{ vault_data_mount }} holds files but is not a mount point. Move them
      aside before mounting the data disk over them.

- name: Create the data disk's filesystem
  community.general.filesystem:
    dev: "{{ vault_data_device }}"
    fstype: ext4
    opts: -L vault-data

# By label, so fstab survives the disk changing slot. No nofail: Vault
# without its data disk would initialise a fresh, empty raft store on the
# root disk. The drop-in in config.yaml holds the service for the mount too.
- name: Mount the data disk
  ansible.posix.mount:
    path: "{{ vault_data_mount }}"
    src: LABEL=vault-data
    fstype: ext4
    opts: defaults
    state: mounted
```

- [x] **Step 8: Create `tasks/config.yaml`**

```yaml
---
- name: Create the Vault directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: vault
    group: vault
    mode: "0750"
  loop:
    - "{{ vault_data_dir }}"
    - "{{ vault_audit_log | dirname }}"

- name: Render the Vault configuration
  ansible.builtin.template:
    src: vault.hcl.j2
    dest: "{{ vault_config_dir }}/vault.hcl"
    owner: vault
    group: vault
    mode: "0640"
  notify: Restart vault

- name: Create the vault.service drop-in directory
  ansible.builtin.file:
    path: /etc/systemd/system/vault.service.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Hold Vault until its data disk is mounted
  ansible.builtin.copy:
    dest: /etc/systemd/system/vault.service.d/10-data-disk.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by ansible (roles/vault).
      [Unit]
      RequiresMountsFor={{ vault_data_mount }}
  notify: Restart vault

- name: Rotate the audit log
  ansible.builtin.template:
    src: logrotate-audit.j2
    dest: /etc/logrotate.d/vault-audit
    owner: root
    group: root
    mode: "0644"

- name: Enable and start Vault
  ansible.builtin.systemd_service:
    name: vault
    enabled: true
    state: started
    daemon_reload: true
```

- [x] **Step 9: Rewrite `handlers/main.yaml`**

```yaml
---
# A restart seals Vault. Any run that fires this needs an unseal afterwards.
- name: Restart vault
  ansible.builtin.systemd_service:
    name: vault
    state: restarted
    daemon_reload: true
  when: vault_service_managed | bool

# SIGHUP (the packaged unit's ExecReload) makes Vault re-read its listener
# certificate without restarting, so a renewed certificate does not seal it.
- name: Reload vault
  ansible.builtin.systemd_service:
    name: vault
    state: reloaded
  when: vault_service_managed | bool

- name: Update the CA trust store
  ansible.builtin.command: update-ca-certificates
  changed_when: true
```

- [x] **Step 10: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/vault 2>&1 | tail -1 | cat
cd .. && git add ansible/roles/vault
git commit -m "feat: put vault on raft on its own disk" -m "The data disk is formatted and mounted by label at /var/lib/vault, the
listener takes a certificate, and the LXC capability drop-in is gone:
a VM can grant IPC_LOCK, and mlock stays off because raft memory-maps."
```

---

### Task 3: TLS from a workstation-held CA

**Files:**
- Create: `ansible/roles/vault/tasks/tls.yaml`
- Modify: `ansible/requirements.yml` (add `community.crypto`)
- Test (scratch): `$SCRATCH/vault-tests/tls-test.yaml`

**Interfaces:**
- Consumes: Task 1 defaults; handlers `Reload vault`, `Update the CA trust store` (Task 2).
- Produces: on the host, `{{ vault_tls_dir }}/server.key` (0640 root:`vault_tls_group`), `server.crt`, `ca.crt`; on the workstation `{{ vault_ca_dir }}/ca.key` (0600) and `ca.crt`.

- [x] **Step 1: Write the failing test**

`$SCRATCH/vault-tests/tls-test.yaml` runs the role's TLS tasks against `localhost` with every path in `$SCRATCH`:

```yaml
- name: The CA signs a server certificate with the right names, once
  hosts: all
  gather_facts: false
  vars:
    t: "{{ lookup('ansible.builtin.env', 'SCRATCH') }}/vault-tests/tls"
    vault_address: 10.0.0.133
    vault_ca_dir: "{{ t }}/ca"
    vault_tls_dir: "{{ t }}/server"
    vault_tls_group: "{{ lookup('ansible.builtin.pipe', 'id -gn') }}"
    vault_tls_trust_system: false
    vault_service_managed: false
    host_ips: {master-01: 10.0.0.101, nfs-01: 10.0.0.131}
  tasks:
    - name: Run the TLS tasks
      ansible.builtin.include_role:
        name: vault
        tasks_from: tls

    - name: Verify the chain and the names with openssl
      ansible.builtin.command:
        cmd: >-
          openssl verify -CAfile {{ vault_ca_dir }}/ca.crt
          -verify_hostname vault.mgryn.cc {{ vault_tls_dir }}/server.crt
      changed_when: false

    - name: Read the certificate
      community.crypto.x509_certificate_info:
        path: "{{ vault_tls_dir }}/server.crt"
      register: cert

    - name: SANs, lifetime and usage
      ansible.builtin.assert:
        that:
          - "cert.subject_alt_name | sort == ['DNS:vault-02', 'DNS:vault.mgryn.cc', 'IP:10.0.0.133'] | sort"
          - "((cert.not_after | to_datetime('%Y%m%d%H%M%SZ')) - (cert.not_before | to_datetime('%Y%m%d%H%M%SZ'))).days in [824, 825]"
          - "'TLS Web Server Authentication' in cert.extended_key_usage"
        fail_msg: "{{ cert }}"

    - name: The CA key stays private
      ansible.builtin.stat:
        path: "{{ vault_ca_dir }}/ca.key"
      register: ca_key
    - name: Mode 0600
      ansible.builtin.assert:
        that: ca_key.stat.mode == '0600'
```

Run it three times from a clean `$SCRATCH/vault-tests/tls`:

```bash
cd $SCRATCH/vault-tests && rm -rf tls && export SCRATCH
RUN tls-test.yaml                                             # run 1: creates
sha1sum tls/server/server.crt > tls/run1.sha
RUN tls-test.yaml                                             # run 2: idempotent
sha1sum -c tls/run1.sha                                       # must print OK
RUN tls-test.yaml -e vault_cert_renew_within_days=900         # run 3: inside the window
sha1sum -c tls/run1.sha                                       # must print FAILED
```

- [x] **Step 2: Run it to verify it fails** — expected: FAIL, `tls.yaml` does not exist.

- [x] **Step 3: Add the collection to `ansible/requirements.yml`**

```yaml
  - name: community.crypto
    version: "3.4.0"
```

and extend the file's header comment: `roles/vault` needs `community.crypto` for its CA and server certificate.

- [x] **Step 4: Create `tasks/tls.yaml`**

```yaml
---
# The CA lives on the workstation that runs Ansible. Its key never reaches
# the Vault host: the host makes its own key and a signing request, the
# workstation signs it, and only the certificate travels back.
#
# Every workstation task says become: false. The playbook becomes root on
# the Vault host, and without this Ansible would try sudo on the
# workstation too.
- name: Create the CA directory on the workstation
  ansible.builtin.file:
    path: "{{ vault_ca_dir }}"
    state: directory
    mode: "0700"
  delegate_to: localhost
  become: false
  run_once: true

- name: Create the CA key on the workstation
  community.crypto.openssl_privatekey:
    path: "{{ vault_ca_dir }}/ca.key"
    type: ECC
    curve: secp384r1
    mode: "0600"
  delegate_to: localhost
  become: false
  run_once: true

- name: Build the CA's signing request
  community.crypto.openssl_csr_pipe:
    privatekey_path: "{{ vault_ca_dir }}/ca.key"
    common_name: "{{ vault_ca_common_name }}"
    basic_constraints: ["CA:TRUE"]
    basic_constraints_critical: true
    key_usage: [keyCertSign, cRLSign]
    key_usage_critical: true
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: false
  register: vault_ca_csr

- name: Self-sign the CA certificate
  community.crypto.x509_certificate:
    path: "{{ vault_ca_dir }}/ca.crt"
    csr_content: "{{ vault_ca_csr.csr }}"
    privatekey_path: "{{ vault_ca_dir }}/ca.key"
    provider: selfsigned
    selfsigned_not_after: "+{{ vault_ca_validity_days }}d"
    mode: "0644"
  delegate_to: localhost
  become: false
  run_once: true

- name: Create the TLS directory
  ansible.builtin.file:
    path: "{{ vault_tls_dir }}"
    state: directory
    group: "{{ vault_tls_group }}"
    mode: "0750"

- name: Create the server key
  community.crypto.openssl_privatekey:
    path: "{{ vault_tls_dir }}/server.key"
    type: ECC
    curve: secp384r1
    group: "{{ vault_tls_group }}"
    mode: "0640"

- name: Build the server's signing request
  community.crypto.openssl_csr_pipe:
    privatekey_path: "{{ vault_tls_dir }}/server.key"
    common_name: "{{ vault_tls_dns_names | last }}"
    subject_alt_name: >-
      {{ ['IP:' ~ vault_address]
         + (vault_tls_dns_names | map('regex_replace', '^', 'DNS:') | list) }}
    extended_key_usage: [serverAuth]
  changed_when: false
  register: vault_server_csr

- name: Read the current server certificate
  ansible.builtin.slurp:
    src: "{{ vault_tls_dir }}/server.crt"
  register: vault_server_crt_current
  failed_when: false

- name: Check whether the current certificate is inside its renewal window
  community.crypto.x509_certificate_info:
    content: "{{ vault_server_crt_current.content | b64decode }}"
    valid_at:
      renewal: "+{{ vault_cert_renew_within_days }}d"
  register: vault_server_crt_info
  when: vault_server_crt_current.content is defined

# Signs when there is no certificate, when the request no longer matches it
# (a name or the key changed), or when it expires inside the window.
- name: Sign the server certificate on the workstation
  community.crypto.x509_certificate_pipe:
    content: "{{ (vault_server_crt_current.content | b64decode) if vault_server_crt_current.content is defined else omit }}"
    csr_content: "{{ vault_server_csr.csr }}"
    provider: ownca
    ownca_path: "{{ vault_ca_dir }}/ca.crt"
    ownca_privatekey_path: "{{ vault_ca_dir }}/ca.key"
    ownca_not_after: "+{{ vault_cert_validity_days }}d"
    force: "{{ vault_server_crt_info.valid_at.renewal is defined and not vault_server_crt_info.valid_at.renewal }}"
  delegate_to: localhost
  become: false
  register: vault_server_crt

- name: Install the server certificate
  ansible.builtin.copy:
    content: "{{ vault_server_crt.certificate }}"
    dest: "{{ vault_tls_dir }}/server.crt"
    group: "{{ vault_tls_group }}"
    mode: "0644"
  notify: Reload vault

- name: Install the CA certificate beside it
  ansible.builtin.copy:
    content: "{{ lookup('ansible.builtin.file', vault_ca_dir ~ '/ca.crt') }}\n"
    dest: "{{ vault_tls_dir }}/ca.crt"
    mode: "0644"

- name: Trust the CA on the Vault host
  ansible.builtin.copy:
    content: "{{ lookup('ansible.builtin.file', vault_ca_dir ~ '/ca.crt') }}\n"
    dest: /usr/local/share/ca-certificates/homelab-vault-ca.crt
    owner: root
    group: root
    mode: "0644"
  when: vault_tls_trust_system | bool
  notify: Update the CA trust store
```

- [x] **Step 5: Run the three-run test** — expected: run 1 passes all assertions; run 2 passes and `sha1sum -c` prints `OK`; run 3 passes and `sha1sum -c` prints `FAILED` (a new certificate). No `failed=` other than 0 in any recap. If `openssl verify` rejects `-verify_hostname`, the local openssl is older than 1.1.0 — report it rather than dropping the flag. If `x509_certificate_pipe` rejects `force` or `content`, report the module's error: the renewal logic hinges on them.

- [x] **Step 6: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/vault 2>&1 | tail -1 | cat
cd .. && git add ansible/roles/vault/tasks/tls.yaml ansible/requirements.yml
git commit -m "feat: issue vault's tls certificate from a local ca" -m "The CA key stays in ~/.homelab-ca on the workstation. The host makes
its own key and request, the workstation signs it for 825 days, and a
run within 30 days of expiry signs a fresh one and reloads Vault."
```

---

### Task 4: The snapshot job

**Files:**
- Create: `ansible/roles/vault/files/vault-snapshot.sh`, `ansible/roles/vault/files/vault-snapshot.service`, `ansible/roles/vault/files/vault-snapshot.timer`, `ansible/roles/vault/templates/snapshot.env.j2`, `ansible/roles/vault/tasks/snapshot_host.yaml`
- Test (scratch): `$SCRATCH/vault-tests/snapshot-test.sh`

**Interfaces:**
- Consumes: Task 1 defaults.
- Produces: `/usr/local/sbin/vault-snapshot`, reading `VAULT_SNAPSHOT_DIR`, `VAULT_SNAPSHOT_KEEP`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID` (plus `VAULT_ADDR`, `VAULT_CACERT` for the CLI); units `vault-snapshot.service` (oneshot, `EnvironmentFile=/etc/vault.d/snapshot.env`) and `vault-snapshot.timer` (not enabled here — Task 5 enables it once credentials exist); template `snapshot.env.j2` taking `vault_snapshot_role_id`, `vault_snapshot_secret_id`.

- [x] **Step 1: Write the failing test**

`$SCRATCH/vault-tests/snapshot-test.sh` drives the script with stand-ins for `vault`, `mountpoint` and `mount` on `PATH`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT=/home/ubuntu/homelab/ansible/roles/vault/files/vault-snapshot.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/backups"
fails=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

cat > "$T/bin/mountpoint" <<'EOF'
#!/bin/sh
[ "${TEST_MOUNTED:-1}" = 1 ]
EOF
cat > "$T/bin/mount" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$T/bin/vault" <<'EOF'
#!/bin/sh
echo "$*" >> "$TEST_LOG"
case "$1 $2" in
  "write -field=token") cat > "$TEST_STDIN"; echo s.fake-token ;;
  "operator raft") [ "${TEST_VAULT_FAIL:-0}" = 1 ] && exit 2; echo snapshot > "$5" ;;
  "token revoke") ;;
esac
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" TEST_LOG="$T/log" TEST_STDIN="$T/stdin"
export VAULT_SNAPSHOT_DIR="$T/backups" VAULT_SNAPSHOT_KEEP=14 VAULT_ROLE_ID=role-123 VAULT_SECRET_ID=secret-456

for i in $(seq -w 1 16); do touch "$T/backups/vault-202601${i}T000000Z.snap"; done
touch "$T/backups/unrelated.txt"

bash "$SCRIPT" > "$T/out" 2>&1; rc=$?
check "exits 0 when mounted"                      "[ $rc -eq 0 ]"
check "keeps exactly 14 snapshots"                "[ \$(ls $T/backups/vault-*.snap | wc -l) -eq 14 ]"
check "the new snapshot is among them"            "ls $T/backups | grep '^vault-' | grep -qv '^vault-202601'"
check "the three oldest are gone"                 "[ ! -e $T/backups/vault-20260101T000000Z.snap ] && [ ! -e $T/backups/vault-20260103T000000Z.snap ]"
check "unrelated files are left alone"            "[ -e $T/backups/unrelated.txt ]"
check "no .partial file remains"                  "! ls $T/backups | grep -q partial"
check "secret_id goes over stdin, not argv"       "grep -q 'secret_id=-' $T/log && ! grep -q secret-456 $T/log && grep -q secret-456 $T/stdin"
check "the token is revoked afterwards"           "grep -q 'token revoke -self' $T/log"

: > "$T/log"; before=$(ls "$T/backups" | wc -l)
TEST_MOUNTED=0 bash "$SCRIPT" > "$T/out" 2>&1; rc=$?
check "not mounted: exits non-zero"               "[ $rc -ne 0 ]"
check "not mounted: says why"                     "grep -q 'not mounted' $T/out"
check "not mounted: never logs in"                "[ ! -s $T/log ]"
check "not mounted: writes nothing"               "[ \$(ls $T/backups | wc -l) -eq $before ]"

TEST_VAULT_FAIL=1 bash "$SCRIPT" > "$T/out" 2>&1; rc=$?
check "snapshot failure: exits non-zero"          "[ $rc -ne 0 ]"
check "snapshot failure: prunes nothing"          "[ \$(ls $T/backups/vault-*.snap | wc -l) -eq 14 ]"

bash -n "$SCRIPT" && echo "ok   syntax" || { echo "FAIL syntax"; fails=$((fails+1)); }
echo "failures: $fails"; exit $fails
```

- [x] **Step 2: Run it to verify it fails**

```bash
bash $SCRATCH/vault-tests/snapshot-test.sh
```

Expected: FAIL lines, non-zero exit — the script does not exist.

- [x] **Step 3: Create `files/vault-snapshot.sh`**

```bash
#!/usr/bin/env bash
# Managed by ansible (roles/vault). Run by vault-snapshot.service, which
# reads /etc/vault.d/snapshot.env. Saves one raft snapshot to the backups
# share on nfs-01 and keeps the newest VAULT_SNAPSHOT_KEEP.
set -euo pipefail

: "${VAULT_SNAPSHOT_DIR:?}" "${VAULT_SNAPSHOT_KEEP:?}" "${VAULT_ROLE_ID:?}" "${VAULT_SECRET_ID:?}"

# The share is mounted nofail: vault-02 boots before nfs-01, so at boot the
# mount may simply not be there. Try once, then refuse -- a snapshot
# written into the empty local directory would report success and protect
# nothing.
if ! mountpoint -q "$VAULT_SNAPSHOT_DIR"; then
  mount "$VAULT_SNAPSHOT_DIR" 2>/dev/null || true
fi
if ! mountpoint -q "$VAULT_SNAPSHOT_DIR"; then
  echo "vault-snapshot: $VAULT_SNAPSHOT_DIR is not mounted; refusing to write a snapshot to the local disk" >&2
  exit 1
fi

# secret_id over stdin, so it never appears in the process list.
VAULT_TOKEN="$(printf '%s' "$VAULT_SECRET_ID" |
  vault write -field=token auth/approle/login role_id="$VAULT_ROLE_ID" secret_id=-)"
export VAULT_TOKEN
trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT

name="vault-$(date -u +%Y%m%dT%H%M%SZ).snap"
vault operator raft snapshot save "$VAULT_SNAPSHOT_DIR/$name.partial"
mv "$VAULT_SNAPSHOT_DIR/$name.partial" "$VAULT_SNAPSHOT_DIR/$name"
echo "vault-snapshot: saved $name"

# Names sort by time. Everything past the newest KEEP goes.
find "$VAULT_SNAPSHOT_DIR" -maxdepth 1 -name 'vault-*.snap' -printf '%f\n' |
  sort -r | tail -n +"$((VAULT_SNAPSHOT_KEEP + 1))" |
  while read -r old; do
    rm -f -- "$VAULT_SNAPSHOT_DIR/$old"
    echo "vault-snapshot: pruned $old"
  done
```

- [x] **Step 4: Run the test again** — expected: every line `ok`, `failures: 0`, exit 0.

- [x] **Step 5: Create the units**

`files/vault-snapshot.service`:

```ini
# Managed by ansible (roles/vault).
[Unit]
Description=Save a Vault raft snapshot to the backups share
After=network-online.target vault.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/vault.d/snapshot.env
ExecStart=/usr/local/sbin/vault-snapshot
```

`files/vault-snapshot.timer`:

```ini
# Managed by ansible (roles/vault).
[Unit]
Description=Daily Vault raft snapshot

[Timer]
OnCalendar=daily
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
```

- [x] **Step 6: Create `templates/snapshot.env.j2`**

```
# Managed by ansible (roles/vault). The AppRole below can read
# sys/storage/raft/snapshot and nothing else. Delete this file and re-run
# the role with -e vault_configure=true to issue a new secret_id.
VAULT_ADDR={{ vault_api_url }}
VAULT_CACERT={{ vault_tls_dir }}/ca.crt
VAULT_ROLE_ID={{ vault_snapshot_role_id }}
VAULT_SECRET_ID={{ vault_snapshot_secret_id }}
VAULT_SNAPSHOT_DIR={{ vault_snapshot_dir }}
VAULT_SNAPSHOT_KEEP={{ vault_snapshot_keep }}
```

- [x] **Step 7: Create `tasks/snapshot_host.yaml`**

```yaml
---
# vault-02 starts at order=5, before nfs-01 at order=10. A hard mount would
# stall this boot waiting for a server that is not up yet; nofail lets the
# boot finish, and the snapshot job mounts the share itself and refuses to
# run when it cannot.
- name: Mount the backups share
  ansible.posix.mount:
    path: "{{ vault_snapshot_dir }}"
    src: "{{ vault_snapshot_src }}"
    fstype: nfs
    opts: nofail,_netdev
    state: mounted

- name: Install the snapshot script
  ansible.builtin.copy:
    src: vault-snapshot.sh
    dest: /usr/local/sbin/vault-snapshot
    owner: root
    group: root
    mode: "0750"

- name: Install the snapshot service and timer
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - vault-snapshot.service
    - vault-snapshot.timer
```

- [x] **Step 8: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/vault 2>&1 | tail -1 | cat
cd .. && git add ansible/roles/vault/files ansible/roles/vault/templates/snapshot.env.j2 ansible/roles/vault/tasks/snapshot_host.yaml
git commit -m "feat: add a daily vault snapshot job" -m "Mounts the backups share nofail, refuses to run when it is not mounted,
logs in with an AppRole over stdin, saves a raft snapshot and keeps 14."
```

---

### Task 5: Configure phase, wired and rehearsed

**Files:**
- Create: `ansible/roles/vault/tasks/configure.yaml`, `preflight.yaml`, `kv_mounts.yaml`, `audit.yaml`, `snapshot_approle.yaml`
- Modify: `ansible/roles/vault/tasks/seed.yaml`, `ansible/roles/vault/tasks/main.yaml`
- Test (scratch): `$SCRATCH/vault-rehearsal/` — a real Vault 2.1.0 on `127.0.0.1:8200`

**Interfaces:**
- Consumes: everything from Tasks 1-4. `k8s_auth.yaml` is rewritten in Task 6; here `configure.yaml` imports it under `when: vault_configure_k8s_auth | bool`, and the rehearsal sets that false.
- Produces: `tasks/main.yaml` in its final form; `configure.yaml`; the `vault-snapshot` AppRole and policy; `{{ vault_config_dir }}/snapshot.env`.

- [x] **Step 1: Write the rehearsal (the failing test)**

`$SCRATCH/vault-rehearsal/vars.yaml` — every path in scratch:

```yaml
r: "{{ lookup('ansible.builtin.env', 'SCRATCH') }}/vault-rehearsal/run"
vault_address: 127.0.0.1
vault_listen_address: 127.0.0.1:8200
vault_ca_dir: "{{ r }}/ca"
vault_tls_dir: "{{ r }}/tls"
vault_config_dir: "{{ r }}/config"
vault_data_dir: "{{ r }}/raft"
vault_audit_log: "{{ r }}/log/audit.log"
vault_tls_group: "{{ lookup('ansible.builtin.pipe', 'id -gn') }}"
vault_tls_trust_system: false
vault_service_managed: false
vault_snapshot_dir: "{{ r }}/backups"
vault_snapshot_keep: 3
vault_configure_k8s_auth: false
host_ips: {master-01: 10.0.0.101, nfs-01: 10.0.0.131}
vault_kv:
  jobboard/db: {POSTGRES_PASSWORD: rehearsal-pw, DATABASE_URL: "postgresql://jobboard:rehearsal-pw@postgres:5432/jobboard", JOBBOARD_SECRET: rehearsal-secret}
  cert-manager/cloudflare: {API_TOKEN: rehearsal-token}
```

`$SCRATCH/vault-rehearsal/up.yaml` — builds TLS, starts Vault, initialises and unseals it:

```yaml
- name: Start a throwaway Vault the way the role would configure it
  hosts: all
  gather_facts: false
  vars_files: [vars.yaml]
  tasks:
    - name: Directories
      ansible.builtin.file: {path: "{{ item }}", state: directory, mode: "0700"}
      loop: ["{{ r }}", "{{ vault_config_dir }}", "{{ vault_data_dir }}", "{{ vault_audit_log | dirname }}", "{{ vault_snapshot_dir }}", "{{ r }}/bin"]
    - name: TLS, through the role
      ansible.builtin.include_role: {name: vault, tasks_from: tls}
    - name: vault.hcl, from the role's template
      ansible.builtin.template:
        src: /home/ubuntu/homelab/ansible/roles/vault/templates/vault.hcl.j2
        dest: "{{ vault_config_dir }}/vault.hcl"
        mode: "0600"
    - name: Fetch Vault 2.1.0
      ansible.builtin.unarchive:
        src: https://releases.hashicorp.com/vault/2.1.0/vault_2.1.0_linux_amd64.zip
        dest: "{{ r }}/bin"
        remote_src: true
        creates: "{{ r }}/bin/vault"
    - name: Start it
      ansible.builtin.shell: >-
        nohup {{ r }}/bin/vault server -config={{ vault_config_dir }}/vault.hcl
        > {{ r }}/server.log 2>&1 & echo $! > {{ r }}/vault.pid
      args: {creates: "{{ r }}/vault.pid"}
    - name: Wait for the listener
      ansible.builtin.wait_for: {host: 127.0.0.1, port: 8200, timeout: 30}
    - name: Initialise
      ansible.builtin.uri:
        url: "{{ vault_api_url }}/v1/sys/init"
        method: PUT
        ca_path: "{{ vault_tls_dir }}/ca.crt"
        body_format: json
        body: {secret_shares: 1, secret_threshold: 1}
      register: init
    - name: Keep the keys for the other plays
      ansible.builtin.copy:
        content: "{{ init.json | to_json }}"
        dest: "{{ r }}/init.json"
        mode: "0600"
    - name: Unseal
      ansible.builtin.uri:
        url: "{{ vault_api_url }}/v1/sys/unseal"
        method: PUT
        ca_path: "{{ vault_tls_dir }}/ca.crt"
        body_format: json
        body: {key: "{{ init.json['keys'][0] }}"}
```

`$SCRATCH/vault-rehearsal/configure.yaml` — the role's configure and seed phases, then the snapshot job:

```yaml
- name: Configure and seed through the role
  hosts: all
  gather_facts: false
  vars_files: [vars.yaml]
  vars:
    vault_token: "{{ (lookup('ansible.builtin.file', r ~ '/init.json') | from_json).root_token }}"
    vault_seed: true
  tasks:
    - name: Configure
      ansible.builtin.include_role: {name: vault, tasks_from: configure}
    - name: Seed
      ansible.builtin.include_role: {name: vault, tasks_from: seed}
      when: vault_seed | bool
```

`$SCRATCH/vault-rehearsal/check.sh` — the assertions against the running Vault:

```bash
#!/usr/bin/env bash
set -uo pipefail
R="$SCRATCH/vault-rehearsal/run"; V="$R/bin/vault"
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT="$R/tls/ca.crt"
export VAULT_TOKEN=$(python3 -c "import json;print(json.load(open('$R/init.json'))['root_token'])")
fails=0; check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

check "storage is raft"                    "$V status -format=json | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"storage_type\"]==\"raft\"'"
check "kv-dev is KV v2"                    "$V secrets list -format=json | python3 -c 'import json,sys; m=json.load(sys.stdin); assert m[\"kv-dev/\"][\"options\"][\"version\"]==\"2\"'"
check "kv-prod is KV v2"                   "$V secrets list -format=json | python3 -c 'import json,sys; m=json.load(sys.stdin); assert m[\"kv-prod/\"][\"options\"][\"version\"]==\"2\"'"
check "no secret/ mount"                   "! $V secrets list -format=json | grep -q '\"secret/\"'"
check "seeded into kv-dev"                 "[ \"\$($V kv get -field=POSTGRES_PASSWORD kv-dev/jobboard/db)\" = rehearsal-pw ]"
check "kv-prod left empty"                 "! $V kv list kv-prod/"
check "file audit device enabled"          "$V audit list -format=json | grep -q '\"file/\"'"
check "the read is in the audit log"       "grep -q 'kv-dev/data/jobboard/db' $R/log/audit.log"
check "snapshot.env is 0600"               "[ \$(stat -c %a $R/config/snapshot.env) = 600 ]"
check "snapshot policy is exactly one path" "[ \"\$($V policy read vault-snapshot | grep -c '^path')\" = 1 ] && $V policy read vault-snapshot | grep -q 'sys/storage/raft/snapshot'"

# The snapshot job itself, with a stand-in mountpoint: the backups dir is not a real mount here.
mkdir -p "$R/shim"; printf '#!/bin/sh\nexit 0\n' > "$R/shim/mountpoint"; chmod +x "$R/shim/mountpoint"
for i in 1 2 3 4; do
  (set -a; . "$R/config/snapshot.env"; set +a; unset VAULT_TOKEN; PATH="$R/shim:$R/bin:$PATH" bash /home/ubuntu/homelab/ansible/roles/vault/files/vault-snapshot.sh) || fails=$((fails+1))
  sleep 1.1
done
check "keeps vault_snapshot_keep (3)"      "[ \$(ls $R/backups/vault-*.snap | wc -l) -eq 3 ]"
check "the snapshot is a real one"         "$V operator raft snapshot inspect \$(ls -t $R/backups/vault-*.snap | head -1)"
check "the AppRole token cannot read KV"   "(set -a; . $R/config/snapshot.env; set +a; unset VAULT_TOKEN; t=\$(printf %s \"\$VAULT_SECRET_ID\" | $V write -field=token auth/approle/login role_id=\"\$VAULT_ROLE_ID\" secret_id=-); ! VAULT_TOKEN=\$t $V kv get kv-dev/jobboard/db)"
echo "failures: $fails"; exit $fails
```

`$SCRATCH/vault-rehearsal/down.sh`:

```bash
#!/usr/bin/env bash
R="$SCRATCH/vault-rehearsal/run"
[ -f "$R/vault.pid" ] && kill "$(cat "$R/vault.pid")" 2>/dev/null
sleep 1; rm -rf "$R"
```

The full run:

```bash
cd $SCRATCH/vault-rehearsal && export SCRATCH
bash down.sh
RUN up.yaml
RUN configure.yaml | tee run1.log | tail -3
bash check.sh
RUN configure.yaml -e vault_seed=false | tee run2.log | tail -3   # idempotence
grep -E '^vault-02' run2.log
bash down.sh
```

- [x] **Step 2: Run it to verify it fails** — expected: `up.yaml` passes (Tasks 2-3 exist); `configure.yaml` fails — `configure.yaml` does not exist in the role.

- [x] **Step 3: Create `tasks/preflight.yaml`**

```yaml
---
- name: Require a Vault token
  ansible.builtin.assert:
    that:
      - vault_token is defined
      - vault_token | length > 0
    fail_msg: >-
      Pass the Vault root token for this run: -e vault_token=...
      It is deliberately absent from secret.yaml and from role defaults.

- name: Ask Vault whether it is initialised and unsealed
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/health"
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    status_code: [200, 429, 472, 473, 501, 503]
  register: vault_health

- name: Require an initialised, unsealed Vault
  ansible.builtin.assert:
    that:
      - vault_health.status == 200
    fail_msg: >-
      Vault answered {{ vault_health.status }}: 501 is not initialised, 503
      is sealed. Initialise and unseal it by hand first (docs/rebuild.md) --
      this role never sees the unseal key.
```

- [x] **Step 4: Create `tasks/kv_mounts.yaml`**

```yaml
---
- name: List the secrets engines
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/mounts"
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
  register: vault_mounts

- name: Enable each KV v2 mount
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/mounts/{{ item }}"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      type: kv
      options:
        version: "2"
    status_code: [200, 204]
  loop: "{{ vault_kv_mounts }}"
  when: (item ~ '/') not in vault_mounts.json.data
  changed_when: true
```

- [x] **Step 5: Create `tasks/audit.yaml`**

```yaml
---
- name: List the audit devices
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/audit"
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
  register: vault_audit_devices

# From here on, a Vault that cannot write this file refuses every request.
- name: Enable the file audit device
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/audit/file"
    method: PUT
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      type: file
      options:
        file_path: "{{ vault_audit_log }}"
    status_code: [200, 204]
  when: "'file/' not in vault_audit_devices.json.data"
  changed_when: true
```

- [x] **Step 6: Create `tasks/snapshot_approle.yaml`**

```yaml
---
- name: List the auth methods
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/auth"
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
  register: vault_auth_methods

- name: Enable the approle auth method
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/auth/approle"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      type: approle
    status_code: [200, 204]
  when: "'approle/' not in vault_auth_methods.json.data"
  changed_when: true

- name: Write the snapshot policy
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/policies/acl/{{ vault_snapshot_role }}"
    method: PUT
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      policy: |
        path "sys/storage/raft/snapshot" {
          capabilities = ["read"]
        }
    status_code: [200, 204]
  changed_when: false

# Not the root token, and not a token that expires quietly: the secret_id
# never expires and each login gets a 10-minute token, revoked when the job
# ends.
- name: Write the snapshot role
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/auth/approle/role/{{ vault_snapshot_role }}"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      token_policies: ["{{ vault_snapshot_role }}"]
      token_ttl: 10m
      token_max_ttl: 10m
      secret_id_ttl: 0
      secret_id_num_uses: 0
    status_code: [200, 204]
  changed_when: false

- name: Look for existing snapshot credentials
  ansible.builtin.stat:
    path: "{{ vault_config_dir }}/snapshot.env"
  register: vault_snapshot_env

# Only when the file is absent, so re-runs do not pile up secret_ids.
- name: Issue the snapshot credentials
  when: not vault_snapshot_env.stat.exists
  block:
    - name: Read the role_id
      ansible.builtin.uri:
        url: "{{ vault_api_url }}/v1/auth/approle/role/{{ vault_snapshot_role }}/role-id"
        ca_path: "{{ vault_tls_dir }}/ca.crt"
        headers:
          X-Vault-Token: "{{ vault_token }}"
      register: vault_snapshot_role_id_response

    - name: Issue a secret_id
      ansible.builtin.uri:
        url: "{{ vault_api_url }}/v1/auth/approle/role/{{ vault_snapshot_role }}/secret-id"
        method: POST
        ca_path: "{{ vault_tls_dir }}/ca.crt"
        headers:
          X-Vault-Token: "{{ vault_token }}"
      register: vault_snapshot_secret_id_response
      no_log: true

    - name: Write the snapshot credentials
      ansible.builtin.template:
        src: snapshot.env.j2
        dest: "{{ vault_config_dir }}/snapshot.env"
        mode: "0600"
      vars:
        vault_snapshot_role_id: "{{ vault_snapshot_role_id_response.json.data.role_id }}"
        vault_snapshot_secret_id: "{{ vault_snapshot_secret_id_response.json.data.secret_id }}"
      no_log: true

- name: Enable the snapshot timer
  ansible.builtin.systemd_service:
    name: vault-snapshot.timer
    enabled: true
    state: started
    daemon_reload: true
  when: vault_service_managed | bool
```

(`owner: root` on the credentials file is implied by the play's `become`; the rehearsal runs unprivileged and must be able to write it.)

- [x] **Step 7: Create `tasks/configure.yaml`**

```yaml
---
- name: Check the token and Vault's state
  ansible.builtin.import_tasks: preflight.yaml

- name: Create the KV mounts
  ansible.builtin.import_tasks: kv_mounts.yaml

- name: Enable the audit log
  ansible.builtin.import_tasks: audit.yaml

- name: Configure each cluster's Kubernetes auth
  ansible.builtin.import_tasks: k8s_auth.yaml
  when: vault_configure_k8s_auth | bool

- name: Set up the snapshot AppRole
  ansible.builtin.import_tasks: snapshot_approle.yaml
```

- [x] **Step 8: Rewrite `tasks/seed.yaml`**

```yaml
---
- name: Check the token and Vault's state
  ansible.builtin.import_tasks: preflight.yaml

- name: Create the KV mounts
  ansible.builtin.import_tasks: kv_mounts.yaml

# secret.yaml's keys are unprefixed; the mount decides the environment.
# Every run writes a new KV version of each path.
- name: Seed the KV paths
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/{{ vault_kv_mount }}/data/{{ item.key }}"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      data: "{{ item.value }}"
    status_code: 200
  loop: "{{ vault_kv | dict2items }}"
  loop_control:
    label: "{{ item.key }}"
  no_log: true
```

- [x] **Step 9: Rewrite `tasks/main.yaml`**

```yaml
---
- name: Validate vault_k8s_clusters
  ansible.builtin.import_tasks: validate_clusters.yaml

- name: Install Vault
  ansible.builtin.import_tasks: install.yaml

- name: Mount the data disk
  ansible.builtin.import_tasks: disk.yaml

- name: Issue the TLS certificate
  ansible.builtin.import_tasks: tls.yaml

- name: Configure and start the service
  ansible.builtin.import_tasks: config.yaml

- name: Install the snapshot job
  ansible.builtin.import_tasks: snapshot_host.yaml

# Needs an initialised, unsealed Vault and -e vault_token=<root token>.
- name: Configure Vault
  ansible.builtin.import_tasks: configure.yaml
  when: vault_configure | bool

- name: Seed the KV store
  ansible.builtin.import_tasks: seed.yaml
  when: vault_seed | bool
```

- [x] **Step 10: Run the rehearsal** — the full run from Step 1. Expected: `up.yaml` and `configure.yaml` recaps with `failed=0`; `check.sh` prints only `ok` lines and `failures: 0`; the second `configure.yaml` run's recap shows `changed=0`. Keep `run1.log`, `run2.log` and the `check.sh` output for the report. If Vault fails to start, read `run/server.log` before changing anything.

- [x] **Step 11: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/vault 2>&1 | tail -1 | cat
cd .. && git add ansible/roles/vault/tasks
git commit -m "feat: configure vault's mounts, audit and snapshots" -m "kv-dev and kv-prod as KV v2, a file audit device, and an AppRole that
can only take raft snapshots. Every step first checks the token and
that Vault is initialised and unsealed."
```

---

### Task 6: Per-cluster Kubernetes auth

**Files:**
- Rewrite: `ansible/roles/vault/tasks/k8s_auth.yaml`
- Create: `ansible/roles/vault/tasks/k8s_auth_cluster.yaml`, `ansible/roles/vault/templates/k8s-policy.hcl.j2`
- Test (scratch): `$SCRATCH/vault-tests/k8s-policy-test.yaml`

**Interfaces:**
- Consumes: `vault_k8s_clusters` entries (Task 1 keys), `vault_api_url`, `vault_tls_dir`, `vault_token`.
- Produces: `k8s_auth.yaml` imported by `configure.yaml` (Task 5); template `k8s-policy.hcl.j2` taking `cluster`.

- [x] **Step 1: Write the failing test**

```yaml
- name: Each cluster's policy names its own mount and nothing wider
  hosts: all
  gather_facts: false
  vars:
    clusters:
      - {kv_mount: kv-dev}
      - {kv_mount: kv-prod}
  tasks:
    - name: Render and check each
      ansible.builtin.assert:
        that:
          - policy is search('^path "' ~ cluster.kv_mount ~ '/data/\\*" \\{', multiline=True)
          - policy is search('^path "' ~ cluster.kv_mount ~ '/metadata/\\*" \\{', multiline=True)
          - policy | regex_findall('^path ', multiline=True) | length == 2
          - "'secret/' not in policy"
          - "'\"*' not in policy"
          - policy is search('capabilities = \\["read"\\]')
          - policy is search('capabilities = \\["list", "read"\\]')
        fail_msg: "{{ policy }}"
      vars:
        policy: "{{ lookup('ansible.builtin.template', '/home/ubuntu/homelab/ansible/roles/vault/templates/k8s-policy.hcl.j2') }}"
      loop: "{{ clusters }}"
      loop_control:
        loop_var: cluster
```

Save as `$SCRATCH/vault-tests/k8s-policy-test.yaml`.

- [x] **Step 2: Run it to verify it fails**

```bash
cd $SCRATCH/vault-tests && RUN k8s-policy-test.yaml
```

Expected: FAIL — the template does not exist.

- [x] **Step 3: Create `templates/k8s-policy.hcl.j2`**

```hcl
# Managed by ansible (roles/vault). Cluster {{ cluster.name | default('') }}
# reads its own mount and nothing else.
path "{{ cluster.kv_mount }}/data/*" {
  capabilities = ["read"]
}
path "{{ cluster.kv_mount }}/metadata/*" {
  capabilities = ["list", "read"]
}
```

- [x] **Step 4: Run the test again** — expected: `failed=0`.

- [x] **Step 5: Rewrite `tasks/k8s_auth.yaml`**

```yaml
---
- name: Configure Kubernetes auth for each cluster
  ansible.builtin.include_tasks: k8s_auth_cluster.yaml
  loop: "{{ vault_k8s_clusters }}"
  loop_control:
    loop_var: cluster
    label: "{{ cluster.name }}"
```

- [x] **Step 6: Create `tasks/k8s_auth_cluster.yaml`**

Carry over, verbatim, the two comment blocks of the old `k8s_auth.yaml`: the one above `Read the token reviewer JWT` (why the task is `no_log` and `failed_when: false`) and the assert's `fail_msg`, and the one in the config call about `disable_local_ca_jwt`. The tasks:

```yaml
---
- name: "Read {{ cluster.name }}'s CA certificate"
  ansible.builtin.slurp:
    src: /etc/kubernetes/pki/ca.crt
  delegate_to: "{{ cluster.control_plane_host }}"
  register: vault_k8s_ca

# <the old comment block about the token reviewer JWT, verbatim>
- name: "Read {{ cluster.name }}'s token reviewer JWT"
  ansible.builtin.command:
    cmd: >-
      kubectl --kubeconfig /etc/kubernetes/admin.conf -n argocd
      get secret vault-auth-token -o jsonpath={.data.token}
  delegate_to: "{{ cluster.control_plane_host }}"
  register: vault_k8s_jwt
  changed_when: false
  failed_when: false
  no_log: true

- name: Require the token reviewer JWT to have been read
  ansible.builtin.assert:
    that:
      - vault_k8s_jwt.rc == 0
      - vault_k8s_jwt.stdout | length > 0
    fail_msg: <the old fail_msg, verbatim>

- name: List the auth methods
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/auth"
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
  register: vault_auth_methods

- name: "Enable the kubernetes auth method at {{ cluster.auth_path }}"
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/auth/{{ cluster.auth_path }}"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      type: kubernetes
    status_code: [200, 204]
  when: (cluster.auth_path ~ '/') not in vault_auth_methods.json.data
  changed_when: true

- name: "Point {{ cluster.auth_path }} at {{ cluster.name }}'s API server"
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/auth/{{ cluster.auth_path }}/config"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      kubernetes_host: "https://{{ cluster.api_host }}:6443"
      kubernetes_ca_cert: "{{ vault_k8s_ca.content | b64decode }}"
      token_reviewer_jwt: "{{ vault_k8s_jwt.stdout | b64decode }}"
      # <the old disable_local_ca_jwt comment, verbatim>
      disable_local_ca_jwt: true
    status_code: [200, 204]
  no_log: true

- name: "Write the {{ cluster.policy_name }} policy"
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/sys/policies/acl/{{ cluster.policy_name }}"
    method: PUT
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      policy: "{{ lookup('ansible.builtin.template', 'k8s-policy.hcl.j2') }}"
    status_code: [200, 204]

# <the old comment about Vault answering 200 with a warning and 204 without, verbatim>
- name: "Bind the {{ cluster.role_name }} role to {{ cluster.name }}'s ServiceAccounts"
  ansible.builtin.uri:
    url: "{{ vault_api_url }}/v1/auth/{{ cluster.auth_path }}/role/{{ cluster.role_name }}"
    method: POST
    ca_path: "{{ vault_tls_dir }}/ca.crt"
    headers:
      X-Vault-Token: "{{ vault_token }}"
    body_format: json
    body:
      bound_service_account_names: "{{ cluster.service_account_names }}"
      bound_service_account_namespaces: "{{ cluster.service_account_namespaces }}"
      policies: ["{{ cluster.policy_name }}"]
      ttl: 1h
    status_code: [200, 204]
```

- [x] **Step 7: Rehearse the rest of the configure phase with k8s auth off**

Re-run Task 5's full rehearsal (Step 1's run block). Expected: unchanged — `failures: 0`, second run `changed=0`. This proves the import wiring still parses; the delegated reads can only run against the real cluster (Task 10).

- [x] **Step 8: Lint, syntax-check with both inventories, commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/vault 2>&1 | tail -1 | cat
/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml --syntax-check 2>&1 | cat
git -C .. add ansible/roles/vault
git -C .. commit -m "feat: give each cluster its own vault auth and mount" -m "vault_k8s_clusters drives the kubernetes auth mount, its config, a
policy on that cluster's KV mount alone, and the role. The CA and
token reviewer reads are delegated to each cluster's control plane."
```

---

### Task 7: The CoreDNS pin

**Files:**
- Create: `ansible/roles/coredns_hosts/defaults/main.yaml`, `ansible/roles/coredns_hosts/tasks/main.yaml`, `ansible/roles/coredns_hosts/templates/hosts-block.j2`, `ansible/playbooks/coredns_hosts.yaml`
- Test (scratch): `$SCRATCH/vault-tests/corefile-test.yaml`

**Interfaces:**
- Consumes: `host_ips['vault-02']` (operator adds it to `secret.yaml` in PR 1 — done).
- Produces: role `coredns_hosts` with `coredns_hosts_entries` (list of `{ip, names}`), `coredns_hosts_kubeconfig`; fact `coredns_hosts_corefile_new`.

- [x] **Step 1: Write the failing test**

`$SCRATCH/vault-tests/corefile-test.yaml` feeds kubeadm 1.33's default Corefile through the transformation the role uses:

```yaml
- name: The hosts block lands before forward, once, and replaces itself
  hosts: all
  gather_facts: false
  vars_files:
    - /home/ubuntu/homelab/ansible/roles/coredns_hosts/defaults/main.yaml
  vars:
    host_ips: {vault-02: 10.0.0.133}
    block_re: '(?ms)^[ \t]*# BEGIN ansible coredns_hosts\n.*?^[ \t]*# END ansible coredns_hosts\n'
    kubeadm_corefile: |
      .:53 {
          errors
          health {
             lameduck 5s
          }
          ready
          kubernetes cluster.local in-addr.arpa ip6.arpa {
             pods insecure
             fallthrough in-addr.arpa ip6.arpa
             ttl 30
          }
          prometheus :9153
          forward . /etc/resolv.conf {
             max_concurrent 1000
          }
          cache 30
          loop
          reload
          loadbalance
      }
  tasks:
    - name: Once
      ansible.builtin.include_role: {name: coredns_hosts, tasks_from: render}
      vars: {coredns_hosts_corefile_current: "{{ kubeadm_corefile }}"}
    - name: Keep the first result
      ansible.builtin.set_fact: {first: "{{ coredns_hosts_corefile_new }}"}

    - name: Twice
      ansible.builtin.include_role: {name: coredns_hosts, tasks_from: render}
      vars: {coredns_hosts_corefile_current: "{{ first }}"}
    - name: Twice changes nothing
      ansible.builtin.assert:
        that: coredns_hosts_corefile_new == first

    - name: With a new address
      ansible.builtin.include_role: {name: coredns_hosts, tasks_from: render}
      vars:
        coredns_hosts_corefile_current: "{{ first }}"
        coredns_hosts_entries: [{ip: 10.0.0.150, names: [vault.mgryn.cc]}]
    - name: Keep the moved result
      ansible.builtin.set_fact: {moved: "{{ coredns_hosts_corefile_new }}"}

    - name: Checks
      ansible.builtin.assert:
        that:
          - "'10.0.0.133 vault.mgryn.cc' in first"
          - "first.index('hosts {') < first.index('forward . /etc/resolv.conf')"
          - "first.index('kubernetes cluster.local') < first.index('hosts {')"
          - "first | regex_findall('hosts \\{') | length == 1"
          - "first | regex_search('hosts \\{[^}]*fallthrough[^}]*\\}') is not none"
          - "(first | regex_replace(block_re, '')) == kubeadm_corefile"
          - "moved | regex_findall('hosts \\{') | length == 1"
          - "'10.0.0.150 vault.mgryn.cc' in moved"
          - "'10.0.0.133' not in moved"
        fail_msg: "{{ first }}\n---\n{{ moved }}"

    - name: A Corefile with no forward line is refused
      block:
        - name: Render one
          ansible.builtin.include_role: {name: coredns_hosts, tasks_from: render}
          vars: {coredns_hosts_corefile_current: ".:53 {\n    errors\n}\n"}
        - name: It should not get here
          ansible.builtin.fail: {msg: rendered a Corefile without forward}
      rescue:
        - name: Refused by the render, not by the guard task
          ansible.builtin.assert:
            that: ansible_failed_task.name != 'It should not get here'
```

- [x] **Step 2: Run it to verify it fails**

```bash
cd $SCRATCH/vault-tests && RUN corefile-test.yaml
```

Expected: FAIL — the role does not exist.

- [x] **Step 3: Create `defaults/main.yaml`**

```yaml
---
# Names the cluster must resolve without the WAN. Ansible owns this pin,
# not ArgoCD: Argo depends on Vault, so letting Argo own the record that
# finds Vault would be a loop that fails exactly when it is needed.
coredns_hosts_entries:
  - ip: "{{ host_ips['vault-02'] }}"
    names: [vault.mgryn.cc]

coredns_hosts_kubeconfig: /etc/kubernetes/admin.conf
```

- [x] **Step 4: Create `templates/hosts-block.j2`**

```
    # BEGIN ansible coredns_hosts
    hosts {
{% for entry in coredns_hosts_entries %}
       {{ entry.ip }} {{ entry.names | join(' ') }}
{% endfor %}
       fallthrough
    }
    # END ansible coredns_hosts
```

- [x] **Step 5: Create `tasks/render.yaml`** (the pure transformation the test drives) and `tasks/main.yaml`

`tasks/render.yaml`:

```yaml
---
# Drop any block an earlier run wrote, then insert the current one before
# the forward plugin. mandatory_count makes a Corefile with no forward line
# fail here instead of silently gaining nothing.
- name: Render the Corefile with the hosts block
  ansible.builtin.set_fact:
    coredns_hosts_corefile_new: >-
      {{ coredns_hosts_corefile_current
         | regex_replace('(?ms)^[ \t]*# BEGIN ansible coredns_hosts\n.*?^[ \t]*# END ansible coredns_hosts\n', '')
         | regex_replace('(?m)^(?=[ \t]*forward )',
                         lookup('ansible.builtin.template', 'hosts-block.j2') | replace('\\', '\\\\'),
                         count=1, mandatory_count=1) }}
```

`tasks/main.yaml`:

```yaml
---
- name: Read the CoreDNS ConfigMap
  kubernetes.core.k8s_info:
    kind: ConfigMap
    name: coredns
    namespace: kube-system
    kubeconfig: "{{ coredns_hosts_kubeconfig }}"
  register: coredns_hosts_configmap

- name: Render the new Corefile
  ansible.builtin.include_tasks: render.yaml
  vars:
    coredns_hosts_corefile_current: "{{ coredns_hosts_configmap.resources[0].data.Corefile }}"

- name: Write the Corefile back
  kubernetes.core.k8s:
    kubeconfig: "{{ coredns_hosts_kubeconfig }}"
    state: present
    definition:
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: coredns
        namespace: kube-system
      data:
        Corefile: "{{ coredns_hosts_corefile_new }}"
  register: coredns_hosts_written

# The reload plugin would pick the change up within a couple of minutes;
# a restart makes it take effect now, while the person who ran this is
# watching.
- name: Restart CoreDNS
  ansible.builtin.command:
    cmd: >-
      kubectl --kubeconfig {{ coredns_hosts_kubeconfig }} -n kube-system
      rollout restart deployment coredns
  when: coredns_hosts_written.changed
  changed_when: true
```

- [x] **Step 6: Run the test again** — expected: every assertion passes, `failed=0`.

- [x] **Step 7: Create `ansible/playbooks/coredns_hosts.yaml`**

```yaml
---
# Pins vault.mgryn.cc (and anything else in coredns_hosts_entries) in the
# cluster's DNS. A kubeadm upgrade can rewrite the coredns ConfigMap: re-run
# this after every cluster upgrade, and check with
#   kubectl run -it --rm dnscheck --image=busybox:1.36 --restart=Never -- nslookup vault.mgryn.cc
- name: Pin names in CoreDNS
  hosts: k8s_control_plane
  become: true
  gather_facts: false

  pre_tasks:
    - name: Install the Python Kubernetes library
      ansible.builtin.apt:
        name: python3-kubernetes
        state: present

  roles:
    - role: coredns_hosts
```

- [x] **Step 8: Lint, syntax-check, commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/coredns_hosts playbooks/coredns_hosts.yaml 2>&1 | tail -1 | cat
/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/dev playbooks/coredns_hosts.yaml --syntax-check 2>&1 | cat
cd .. && git add ansible/roles/coredns_hosts ansible/playbooks/coredns_hosts.yaml
git commit -m "feat: pin vault.mgryn.cc in the cluster's coredns" -m "A hosts block inserted before forward, replaced on every run, so
argocd-vault-plugin finds Vault without the WAN or Cloudflare."
```

---

### Task 8: Playbook, examples and documentation

**Files:**
- Modify: `ansible/playbooks/vault.yaml`, `ansible/secret.yaml.example`, `CLAUDE.md`, `docs/rebuild.md`, `ansible/README.md`

- [x] **Step 1: Point the playbook at the VM**

`ansible/playbooks/vault.yaml`:

```yaml
---
# vault-02, in inventories/shared. Install and TLS need only that inventory:
#   ansible-playbook -i inventories/shared playbooks/vault.yaml -e @secret.yaml --ask-vault-pass
# Configure reaches each cluster's control plane, which lives in
# inventories/dev, so it needs both:
#   ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml \
#     -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=true -e vault_token=<root>
- name: Install and configure HashiCorp Vault
  hosts: vault_vm
  become: true

  roles:
    - role: vault
```

- [x] **Step 2: Add `vault-02` to `ansible/secret.yaml.example`**

`vault-02: 10.0.0.133` under `host_ips` and `vault-02: 105` under `proxmox_vm_ids`, each directly after `vault-01`. Change the `vault_kv` comment's `seed.yaml` usage line to the two-inventory command above, and add one line: "Seeded into `kv-dev/` (`vault_kv_mount`); the keys here stay unprefixed."

- [x] **Step 3: Syntax-check with both inventories**

```bash
cd /home/ubuntu/homelab/ansible && /home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml --syntax-check 2>&1 | cat
```

Expected: `playbook: playbooks/vault.yaml`.

- [x] **Step 4: `CLAUDE.md`**

In "Load-bearing and non-obvious", add one bullet after the "A sealed Vault looks healthy" bullet:

```markdown
- **`vault-02` is HTTPS from a private CA, reached as `vault.mgryn.cc`.**
  The CA's key is in `~/.homelab-ca/` on the workstation that runs
  Ansible and nowhere else; losing it loses no data (re-run the role,
  refresh the `vault-ca` ConfigMap). The name resolves through a
  Cloudflare DNS-only record on the LAN and a `hosts` block in the
  cluster's CoreDNS (`playbooks/coredns_hosts.yaml`) — re-run that after
  every kubeadm upgrade, which can rewrite the ConfigMap. KV is split
  into `kv-dev/` and `kv-prod/`, each cluster's policy reading only its
  own. Raft snapshots go daily to `/srv/nfs/backups` on `nfs-01`, 14
  kept — the same SSD, so they cover a bad upgrade or a deleted secret,
  not a lost disk. **If Vault cannot write `/var/log/vault/audit.log` it
  refuses every request**: a full root disk looks like a healthy Vault
  answering nothing. A restart seals it; a certificate renewal only
  reloads it.
```

Do not change the placeholder rule or the "sealed Vault" bullet's `vault-01` wording — PR 4 and PR 5 do. In the Layout tree, add `vault-vm` to the `modules/` list (`ubuntu-vm, ubuntu-k8s, lxc, nfs-server, vault-vm, talos-*`), missed by PR 1.

- [x] **Step 5: `docs/rebuild.md`**

- The workstation-files table ("4. Files that live only on the workstation"): add a row `~/.homelab-ca/` — "The CA that signs Vault's TLS certificate" — "Regenerable: delete, re-run the vault role, refresh the `vault-ca` ConfigMap. No data is lost."
- "What is destroyed and not backed up": the Vault row gains a sentence — once `vault-02` is in service, raft snapshots land daily in `/srv/nfs/backups` on `nfs-01`, 14 kept, same SSD.
- The rebuild order: after the step that installs and unseals Vault on `vault-01`, add a step "Build `vault-02`" with, in order: `ansible-galaxy collection install -r requirements.yml`; the install run (`-i inventories/shared`); init and unseal by hand on `vault-02` (`export VAULT_ADDR=https://10.0.0.133:8200` — the role put the CA in the host's trust store; `vault operator init -key-shares=1 -key-threshold=1`; `vault operator unseal`); the configure-and-seed run (both inventories, `vault_configure=true vault_seed=true`); the CoreDNS run (`playbooks/coredns_hosts.yaml`); the Cloudflare DNS-only record `vault.mgryn.cc` → `10.0.0.133`. State that it must follow the step that syncs `argocd-config` (the token reviewer Secret) because configure reads it.
- Add a subsection "Restoring Vault from a snapshot" under the rebuild order: the snapshot files are `vault-<UTC timestamp>.snap` in `/srv/nfs/backups`; restoring needs the unseal key and root token the snapshot was taken under; the command sequence on a fresh `vault-02` (after init/unseal of the fresh store): `vault operator raft snapshot restore -force <file>`, then unseal with the **original** key and log in with the **original** root token. The drill that proves it is PR 4's (Task 14).

Keep each edit inside the section it belongs to; do not rewrite the `vault-01` steps (PR 5 removes them).

- [x] **Step 6: `ansible/README.md`**

Wherever it lists playbooks or roles: add `coredns_hosts` (pins `vault.mgryn.cc` in the cluster's CoreDNS; re-run after kubeadm upgrades) and change the `vault` playbook's description to target `vault_vm` in `inventories/shared`, with the two invocations from Step 1.

- [x] **Step 7: Lint and commit**

```bash
cd /home/ubuntu/homelab && pre-commit run --all-files >/dev/null 2>&1; echo "pre-commit rc=$?"
(cd ansible && ansible-lint . 2>&1 | tail -1 | cat)
git add ansible/playbooks/vault.yaml ansible/secret.yaml.example CLAUDE.md docs/rebuild.md ansible/README.md
git commit -m "docs: document the vault vm and point the playbook at it"
```

Expected: `rc=0`, ansible-lint `Passed`.

---

### Task 9: Review and open PR 3

- [x] **Step 1: Full verification**

```bash
cd /home/ubuntu/homelab
(cd ansible && ansible-lint . 2>&1 | tail -1 | cat)
B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin
(cd ansible && $B/ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml --syntax-check 2>&1 | cat; $B/ansible-playbook -i inventories/dev playbooks/coredns_hosts.yaml --syntax-check 2>&1 | cat)
pre-commit run --all-files >/dev/null 2>&1; echo "pre-commit rc=$?"
scripts/check-manifests.sh >/dev/null 2>&1; echo "check-manifests rc=$?"
for t in validate-clusters-test config-render-test k8s-policy-test corefile-test; do (cd $SCRATCH/vault-tests && RUN $t.yaml | grep -E '^vault-02' | sed "s/^/$t: /"); done
bash $SCRATCH/vault-tests/snapshot-test.sh | tail -1
```

Then the TLS three-run test (Task 3 Step 1) and the rehearsal (Task 5 Step 1). Expected: all `failed=0`, `failures: 0`, rehearsal second run `changed=0`, `rc=0` twice, clean tree.

- [x] **Step 2: Code review** — `superpowers:requesting-code-review` against `main`, fix findings.

- [x] **Step 3: Pre-merge checks** — `superpowers:finishing-a-development-branch`; push and open a PR. Never merge. Before pushing, the supervisor ticks Tasks 1-9 here and the unticked Task 10 boxes in `docs/superpowers/plans/2026-09-25-vault-vm-infra.md` (verified 2026-09-25), in one `docs:` commit.

- [x] **Step 4: PR body** to `$SCRATCH/pr-vault-role.md`: what the role now does (raft on the data disk, TLS from `~/.homelab-ca`, audit, `kv-dev`/`kv-prod`, per-cluster auth, snapshot AppRole and timer), the CoreDNS role, that **`vault-01` keeps serving and nothing points at `vault-02` yet**, the local evidence (the tests and the rehearsal against a real Vault 2.1.0), and Task 10 verbatim as operator steps.

- [x] **Step 5: Push and open**

```bash
git push -u origin vault-role-rebuild
gh pr create --base main --head vault-role-rebuild --title "feat: rebuild the vault role for the vault vm" --body-file $SCRATCH/pr-vault-role.md
```

---

### Task 10: Operator steps for PR 3 (repository owner)

Not for agents. On the Mac, after PR 3 merges and `git pull`. Any unexpected output: stop and paste it.

- [ ] **Step 1: Collections** — `cd ansible && ansible-galaxy collection install -r requirements.yml` (adds `community.crypto`).

- [ ] **Step 2: Install** — `ansible-playbook -i inventories/shared playbooks/vault.yaml -e @secret.yaml --ask-vault-pass`. Expected: `~/.homelab-ca/{ca.key,ca.crt}` created on the Mac, the data disk formatted `vault-data` and mounted, `/mnt/vault-backups` mounted, Vault running uninitialised.

- [ ] **Step 3: Initialise and unseal, by hand on `vault-02`**

```bash
export VAULT_ADDR=https://10.0.0.133:8200
vault operator init -key-shares=1 -key-threshold=1   # unseal key + root token straight into the password manager
vault operator unseal
vault status                                           # Storage Type raft, Sealed false
```

- [ ] **Step 4: Configure and seed** — `ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=true -e vault_token=<root token>`.

- [ ] **Step 5: The name** — Cloudflare DNS-only record `vault.mgryn.cc` → `10.0.0.133`. Check `/etc/hosts` on the Mac for an old `vault.mgryn.cc` line pointing at `10.0.0.132` and remove it. Then `ansible-playbook playbooks/coredns_hosts.yaml -e @secret.yaml --ask-vault-pass`.

- [ ] **Step 6: Verify** (spec, PR 3)

```bash
# on the Mac
openssl s_client -connect vault.mgryn.cc:8200 -CAfile ~/.homelab-ca/ca.crt -verify_hostname vault.mgryn.cc -verify_return_error </dev/null 2>&1 | grep 'Verify return code'
openssl s_client -connect 10.0.0.133:8200 -CAfile ~/.homelab-ca/ca.crt -verify_ip 10.0.0.133 -verify_return_error </dev/null 2>&1 | grep 'Verify return code'
kubectl run -it --rm dnscheck --image=busybox:1.36 --restart=Never -- nslookup vault.mgryn.cc
# on vault-02, as root with VAULT_TOKEN set
vault kv get -format=json kv-dev/jobboard/db | jq -S .data.data | sha256sum
tail -1 /var/log/vault/audit.log | jq -r .request.path          # kv-dev/data/jobboard/db
systemctl start vault-snapshot.service && journalctl -u vault-snapshot -n 3 --no-pager && ls -l /mnt/vault-backups
systemctl list-timers vault-snapshot.timer
# on vault-01, root token of the OLD Vault
VAULT_ADDR=http://127.0.0.1:8200 vault kv get -format=json secret/jobboard/db | jq -S .data.data | sha256sum   # same hash
```

Expected: `Verify return code: 0 (ok)` twice; `nslookup` answers `10.0.0.133`; the two hashes match; one `.snap` on the share; the timer listed.

The spec asks for the pin to be proven with the WAN unplugged. Either pull the router's WAN cable for the `nslookup`, or compare TTLs: the `hosts` plugin answers with TTL 3600, Cloudflare with 300 — `kubectl run -it --rm dig --image=alpine:3.20 --restart=Never -- sh -c 'apk add -q bind-tools && dig +noall +answer vault.mgryn.cc'`.

- [ ] **Step 7: Reboot with the share unreachable**

Stopping `nfs-01` would take every PVC down with it. Prove `nofail` instead by making the share's server unreachable for one boot: on `vault-02`, `sudo sed -i 's#^10.0.0.131:/srv/nfs/backups#10.0.0.254:/srv/nfs/backups#' /etc/fstab && sudo reboot`. Expected: SSH returns within a couple of minutes; `vault status` shows sealed (unseal it); `sudo systemctl start vault-snapshot.service` fails with "not mounted". Then restore the line (`sed` back, or re-run Step 2) and `sudo mount /mnt/vault-backups`.

- [ ] **Step 8: Report back** — the outputs above, so PR 4 can start.

---

## PR 4 — cutover

Start only after Task 10 passes: `git checkout main && git pull && git checkout -b vault-cutover`.

### Task 11: AVP over HTTPS, by name, trusting the CA

**Files:**
- Modify: `ansible/roles/argocd/defaults/main.yaml`, `ansible/roles/argocd/tasks/main.yaml`
- Test (scratch): `$SCRATCH/vault-tests/argocd-values-test.yaml`

**Interfaces:**
- Consumes: `~/.homelab-ca/ca.crt` on the workstation (Task 10).
- Produces: ConfigMap `vault-ca` in `argocd` (key `ca.crt`), mounted in the `avp` sidecar at `/etc/vault-ca`; `VAULT_ADDR=https://vault.mgryn.cc:8200`, `VAULT_CACERT=/etc/vault-ca/ca.crt`; pod annotation `checksum/vault-ca`.

- [ ] **Step 1: Write the failing test**

```yaml
- name: The repo-server values trust the Vault CA and reach Vault by name
  hosts: all
  gather_facts: false
  vars_files:
    - /home/ubuntu/homelab/ansible/roles/argocd/defaults/main.yaml
  vars:
    host_ips: {vault-01: 10.0.0.132}
    argocd_admin_password_hash: "$2a$10$x"
    argocd_admin_password_mtime: "2026-01-01T00:00:00Z"
    argocd_vault_ca_dir: "{{ lookup('ansible.builtin.env', 'SCRATCH') }}/vault-tests/tls/ca"
    rs: "{{ argocd_helm_values.repoServer }}"
    avp: "{{ rs.extraContainers | selectattr('name', 'equalto', 'avp') | first }}"
  tasks:
    - name: Address, CA path, mount, volume, annotation
      ansible.builtin.assert:
        that:
          - argocd_avp_config.VAULT_ADDR == 'https://vault.mgryn.cc:8200'
          - argocd_avp_config.VAULT_CACERT == '/etc/vault-ca/ca.crt'
          - avp.volumeMounts | selectattr('name', 'equalto', 'vault-ca') | map(attribute='mountPath') | list == ['/etc/vault-ca']
          - rs.volumes | selectattr('name', 'equalto', 'vault-ca') | map(attribute='configMap.name') | list == ['vault-ca']
          - rs.podAnnotations['checksum/vault-ca'] == (argocd_vault_ca_cert | hash('sha1'))
          - "'BEGIN CERTIFICATE' in argocd_vault_ca_cert"
          - rs.podAnnotations['checksum/avp-config'] == (argocd_avp_config | to_json | hash('sha1'))
```

Save as `$SCRATCH/vault-tests/argocd-values-test.yaml`. It reads the CA the Task 3 test created; re-run that test first if `$SCRATCH/vault-tests/tls/ca/ca.crt` is gone.

- [ ] **Step 2: Run it to verify it fails**

```bash
cd $SCRATCH/vault-tests && export SCRATCH && RUN argocd-values-test.yaml
```

Expected: FAIL on `VAULT_ADDR`.

- [ ] **Step 3: Defaults**

Replace `argocd_vault_address: "{{ host_ips['vault-01'] }}"` with:

```yaml
# By name: a future move is a DNS edit, not an Ansible run and a rollout.
# Resolved in the cluster by the CoreDNS pin (playbooks/coredns_hosts.yaml).
argocd_vault_address: vault.mgryn.cc
# The vault role's vault_ca_dir, on the workstation that runs Ansible.
argocd_vault_ca_dir: "~/.homelab-ca"
argocd_vault_ca_cert: "{{ lookup('ansible.builtin.file', argocd_vault_ca_dir ~ '/ca.crt') }}"
```

In `argocd_avp_config`: `VAULT_ADDR: "https://{{ argocd_vault_address }}:8200"` and add `VAULT_CACERT: /etc/vault-ca/ca.crt`. Extend the comment above `argocd_avp_config` by one sentence: VAULT_CACERT points at the `vault-ca` ConfigMap mounted below.

In `repoServer.podAnnotations` add `checksum/vault-ca: "{{ argocd_vault_ca_cert | hash('sha1') }}"`, and extend the annotation comment: the third checksum does the same for the CA — a new CA in the ConfigMap alone would leave the sidecar trusting the old one.

In `extraContainers[avp].volumeMounts` add:

```yaml
          - mountPath: /etc/vault-ca
            name: vault-ca
            readOnly: true
```

and in `repoServer.volumes`:

```yaml
      - configMap:
          name: vault-ca
        name: vault-ca
```

- [ ] **Step 4: Tasks** — in `ansible/roles/argocd/tasks/main.yaml`, directly after `Create the AVP configuration Secret` and before the Helm deploy:

```yaml
- name: Create the Vault CA ConfigMap
  # Before the Helm deploy, for the reason the two tasks above are: the
  # sidecar mounts it, and a missing ConfigMap holds repo-server in Init.
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ argocd_context_kubeconfig }}"
    definition:
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: vault-ca
        namespace: "{{ argocd_namespace }}"
      data:
        ca.crt: "{{ argocd_vault_ca_cert }}"
```

- [ ] **Step 5: Run the test again** — expected: `failed=0`.

- [ ] **Step 6: Lint, syntax-check, commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/argocd 2>&1 | tail -1 | cat
/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/dev playbooks/argocd-dev.yaml --syntax-check 2>&1 | cat
cd .. && git add ansible/roles/argocd
git commit -m "feat: point avp at vault.mgryn.cc over https" -m "The CA ships as a vault-ca ConfigMap mounted into the avp sidecar,
with a third checksum annotation so a new CA rolls the pod."
```

---

### Task 12: Placeholders on `kv-dev/`

**Files:**
- Move: `argocd/apps/jobboard/base/secret.yaml` → `argocd/apps/jobboard/dev/secret.yaml`, `argocd/apps/jobboard/base/ghcr-secret.yaml` → `argocd/apps/jobboard/dev/ghcr-secret.yaml`
- Modify: both kustomizations, `argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml`, `argocd/environments/dev/applications/cert-manager-issuers.yaml` (comment), `ansible/secret.yaml.example` (comments)

- [ ] **Step 1: Record the failing check**

```bash
cd /home/ubuntu/homelab
grep -rn '<path:secret/' argocd/ | wc -l          # 5 now; must become 0
kustomize build argocd/apps/jobboard/base | grep -c '^kind: Secret'   # 2 now; must become 0
```

- [ ] **Step 2: Move the two Secrets into the dev overlay**

```bash
git mv argocd/apps/jobboard/base/secret.yaml argocd/apps/jobboard/dev/secret.yaml
git mv argocd/apps/jobboard/base/ghcr-secret.yaml argocd/apps/jobboard/dev/ghcr-secret.yaml
```

Remove both from `base/kustomization.yaml`'s `resources`; add them to `dev/kustomization.yaml`'s `resources` after `../base`, with a comment: the placeholders name `kv-dev`, and a base a prod overlay also consumes must not carry an environment's mount.

- [ ] **Step 3: Rewrite the five placeholders**

`secret/data/` → `kv-dev/data/` in `dev/secret.yaml` (three), `dev/ghcr-secret.yaml` (one), `cert-manager-issuers/dev/cloudflare-secret.yaml` (one). Update comments that quote a placeholder: `argocd/environments/dev/applications/cert-manager-issuers.yaml` and the `vault_kv` comments in `ansible/secret.yaml.example` (`<path:secret/data/cert-manager/cloudflare#API_TOKEN>` → `kv-dev`).

- [ ] **Step 4: Check**

```bash
grep -rn 'secret/data/' argocd/ ansible/secret.yaml.example         # nothing
grep -rn '<path:kv-dev/data/' argocd/ | wc -l                      # 5
kustomize build argocd/apps/jobboard/base | grep -c '^kind: Secret' # 0
kustomize build argocd/apps/jobboard/dev | grep -c '^kind: Secret'  # 2
kustomize build argocd/apps/cert-manager-issuers/dev | grep -c 'kv-dev/data/cert-manager/cloudflare#API_TOKEN'   # 1
scripts/check-manifests.sh >/dev/null 2>&1; echo rc=$?             # 0
```

- [ ] **Step 5: Commit**

```bash
git add argocd ansible/secret.yaml.example
git commit -m "feat: read argocd secrets from kv-dev" -m "Five placeholders move from secret/ to kv-dev/. The two jobboard
Secrets move from base into the dev overlay, so a prod overlay cannot
inherit a dev mount."
```

---

### Task 13: Documentation, review and PR 4

**Files:**
- Modify: `CLAUDE.md`, `docs/rebuild.md`, `README.md`, `ansible/README.md`

- [ ] **Step 1: `CLAUDE.md`**

- The two places that give the placeholder form (`<path:secret/data/...#FIELD>` in "Load-bearing" and in "Secrets"): `<path:kv-<env>/data/...#FIELD>`, with `kv-dev` today.
- `jobs.mgryn.cc`'s bullet: `secret/cert-manager/cloudflare` → `kv-dev/cert-manager/cloudflare`.
- The `environments/shared` lines (Stack paragraph, layout tree) drop "not yet in service" for `vault-02`, and "will replace" becomes "replacing".

- [ ] **Step 2: `docs/rebuild.md`, `README.md`, `ansible/README.md`** — every `secret/data/...` or `secret/<path>` reference to Vault's KV becomes `kv-dev/...`; every statement that AVP reaches Vault at `vault-01`'s address becomes `https://vault.mgryn.cc:8200`. `grep -rn "secret/data\|secret/jobboard\|secret/cert-manager" CLAUDE.md README.md docs/rebuild.md ansible/README.md` must return nothing. Leave `vault-01` itself alone — PR 5 removes it.

- [ ] **Step 3: Verify** — Task 9 Step 1's command block plus the Task 11 test; `kustomize build` on both jobboard directories.

- [ ] **Step 4: Review and PR** — `superpowers:requesting-code-review`, `superpowers:finishing-a-development-branch`. The supervisor ticks Task 10 and Tasks 11-13 before pushing. PR body to `$SCRATCH/pr-vault-cutover.md`: the two changes, **the accepted window** (after the Ansible run and before the merge, the three apps report `ComparisonError` for about one Argo poll; nothing goes down), and Task 14 verbatim.

```bash
git push -u origin vault-cutover
gh pr create --base main --head vault-cutover --title "feat: cut argocd over to the vault vm" --body-file $SCRATCH/pr-vault-cutover.md
```

---

### Task 14: Operator steps for PR 4 (repository owner)

Not for agents. One sitting.

- [ ] **Step 1: Ansible** — on the Mac, from the `vault-cutover` branch (the merge comes second): `ansible-playbook playbooks/argocd-dev.yaml -e @secret.yaml --ask-vault-pass`. Then `kubectl -n argocd rollout status deploy/argocd-repo-server`.
- [ ] **Step 2: Merge PR 4** at once. Watch `kubectl -n argocd get applications` until `jobboard`, `cert-manager-issuers` and the rest are `Synced`.
- [ ] **Step 3: Verify**

```bash
kubectl -n argocd exec deploy/argocd-repo-server -c avp -- sh -c 'getent hosts vault.mgryn.cc; curl -s --cacert /etc/vault-ca/ca.crt https://vault.mgryn.cc:8200/v1/sys/health | head -c 120'
kubectl -n jobboard get secret -o name
kubectl -n jobboard get secret <db secret> -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | wc -c   # 24, not a <path:...> string
```

- [ ] **Step 4: Restore drill** — the spec's proof that a snapshot is a backup.

```bash
# on the Proxmox host: a throwaway clone of the template
qm clone 5000 199 --name vault-drill --full && qm set 199 --ipconfig0 ip=dhcp && qm start 199
# on vault-02: copy the newest snapshot to the drill VM
ls -t /mnt/vault-backups/vault-*.snap | head -1
# on vault-drill: install Vault 2.1.0-1 from the HashiCorp apt repo, then a scratch config
#   storage "raft" { path = "/tmp/raft"  node_id = "drill" }
#   listener "tcp" { address = "127.0.0.1:8200"  tls_disable = 1 }
#   disable_mlock = true
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init -key-shares=1 -key-threshold=1 && vault operator unseal <drill key>
VAULT_TOKEN=<drill root> vault operator raft snapshot restore -force /tmp/<snapshot>.snap
vault operator unseal <PRODUCTION unseal key>
VAULT_TOKEN=<PRODUCTION root> vault kv get -format=json kv-dev/jobboard/db | jq -S .data.data | sha256sum   # same hash as Task 10
# on the Proxmox host
qm stop 199 && qm destroy 199 --purge
```

- [ ] **Step 5: Report back**, then PR 5 the same day.

---

## PR 5 — decommission, same day

`git checkout main && git pull && git checkout -b vault-lxc-decommission`.

### Task 15: Terraform

**Files:**
- Modify: `terraform/environments/dev/{main,variables}.tf`, `terraform/environments/dev/dev.tfvars.example`, `terraform/environments/prod/{main,variables,outputs}.tf`, `terraform/environments/prod/prod.tfvars.example`

- [ ] **Step 1: Remove** `module "vault"` and its banner comment from dev `main.tf`; `variable "vault_lxc_ip"` and its comment from dev `variables.tf`; the Vault lines (comment and `vault_lxc_ip`) from `dev.tfvars.example`, and the example's comment that the LXC template is "required now that the vault container uses it" if no other container in dev uses `modules/lxc` (`grep -n 'modules/lxc' terraform/environments/dev/main.tf` decides). From prod: `module "vault_lxc"`, `variable "vault_ip"`, `output "vault_details"`, `vault_ip` in `prod.tfvars.example`, and "Vault" from that file's line-5 list.

- [ ] **Step 2: Validate**

```bash
cd /home/ubuntu/homelab
grep -rn -i "vault" terraform/environments/dev terraform/environments/prod | grep -v -i "argocd-vault-plugin"   # nothing
S=$(mktemp -d); git archive HEAD terraform | tar -x -C $S; cp -r terraform/environments $S/terraform/
(cd $S/terraform/environments/dev && terraform init -backend=false -input=false >/dev/null && terraform validate && tflint --config=/home/ubuntu/homelab/.tflint.hcl && echo OK dev); rm -rf $S
terraform fmt -recursive -check terraform && echo "fmt ok"
```

Prod cannot `init` at all (its provider pins conflict — a known, separate problem); check it with `terraform fmt -check` and by reading the diff.

- [ ] **Step 3: Commit** — `git commit -m "feat: remove the vault-01 lxc from terraform" -m "The dev container (vmid 104) and prod's never-applied duplicate (vmid 333) go. vault-02 in environments/shared serves both clusters."`

---

### Task 16: Inventories, roles and documentation

**Files:**
- Modify: `ansible/inventories/dev/hosts.yaml`, `ansible/inventories/prod/hosts.yaml`, `ansible/inventories/shared/hosts.yaml`, `ansible/playbooks/vault.yaml`, `ansible/roles/vault/defaults/main.yaml` (comment), `ansible/secret.yaml.example`, `CLAUDE.md`, `docs/rebuild.md`, `README.md`, `ansible/README.md`, `terraform/README.md`

- [ ] **Step 1: Inventories** — delete the `vault` group from `inventories/dev` and `inventories/prod`; in `inventories/shared` rename `vault_vm` to `vault` and rewrite its comment (it is the Vault VM both clusters use; the LXC it replaced is gone). `playbooks/vault.yaml`: `hosts: vault`, comment updated.
- [ ] **Step 2: `secret.yaml.example`** — delete `vault-01` from `host_ips` and `proxmox_vm_ids`.
- [ ] **Step 3: Docs** — `CLAUDE.md`: delete the "Debian LXC template must exist" bullet; the sealed-Vault bullet says `vault-02`; the `environments/shared` lines describe `vault-02` as the Vault. `docs/rebuild.md`: remove the LXC template blocker and `pveam` step if nothing else needs them, the `vault-01` install/unseal/k8s-auth steps (the `vault-02` step from Task 8 replaces them), and `vault-01` from every table; the Vault data row describes raft on `vault-02` with snapshots. `README.md`, `ansible/README.md`, `terraform/README.md`: `vault-01` and the LXC go.
- [ ] **Step 4: Check**

```bash
grep -rn "vault-01\|vault_lxc\|vault_vm\b\|10\.0\.0\.132\|vault-lxc" --exclude-dir=.git --exclude-dir=.superpowers . | grep -v "docs/superpowers"   # nothing
(cd ansible && ansible-lint . 2>&1 | tail -1 | cat)
B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin
(cd ansible && $B/ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml --syntax-check 2>&1 | cat)
pre-commit run --all-files >/dev/null 2>&1; echo rc=$?
```

- [ ] **Step 5: Commit** — `git commit -m "docs: remove every trace of the vault-01 lxc"` (split into `refactor:` for the inventories and `docs:` for prose if the diff reads better that way).

---

### Task 17: Review and PR 5

- [ ] **Step 1:** Task 15 Step 2 and Task 16 Step 4 again on the final tree.
- [ ] **Step 2:** `superpowers:requesting-code-review`, `superpowers:finishing-a-development-branch`.
- [ ] **Step 3:** PR body to `$SCRATCH/pr-vault-decommission.md` — what goes, that the destroy is **irreversible** and happens in Task 18, and Task 18 verbatim. The supervisor ticks Task 14 and Tasks 15-17 before pushing; Task 18's boxes are ticked in whatever PR comes next.

```bash
git push -u origin vault-lxc-decommission
gh pr create --base main --head vault-lxc-decommission --title "feat: decommission the vault-01 lxc" --body-file $SCRATCH/pr-vault-decommission.md
```

---

### Task 18: Operator steps for PR 5 (repository owner)

Not for agents. After merging PR 5.

- [ ] **Step 1:** `cd terraform/environments/dev && terraform plan -var-file=dev.tfvars` — **0 to add, 0 to change, 1 to destroy**, and the one is `module.vault`. Anything else: stop and paste it. Then `terraform apply -var-file=dev.tfvars`.
- [ ] **Step 2:** Remove `vault_lxc_ip` from `dev.tfvars`; remove `vault-01` from `host_ips` and `proxmox_vm_ids` in `secret.yaml` (`ansible-vault edit`). Delete the old Vault's unseal key and root token from the password manager only after Step 3.
- [ ] **Step 3: Verify** — `pct status 104` → no such container; `terraform plan` clean in `dev` and `shared`; `kubectl -n argocd get applications` all `Synced`; `ansible-inventory -i inventories/shared --graph` shows `@vault` with `vault-02`.
