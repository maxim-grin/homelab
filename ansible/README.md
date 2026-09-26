## Directory layout

```txt
.ansible/
├── ansible.cfg                         # Ansible common config
├── secrets.yaml                        # Ansible Vault Secret
├── inventories/                        # All inventory directory
│   └── dev/                            # Dev Environement
│       ├── hosts.yaml                   # Holds all Dev Hosts Data
│       └── group_vars/                 # Group Variables
│           ├── all.yaml
│           ├── k8s_control_plane.yaml
│           └── k8s_workers.yaml
├── playbooks/
│   ├── argocd-dev.yaml          # ArgoCD Setup to Dev Server
│   ├── site.yaml                # Initial Setup for all hosts
│   ├── cluster_init.yaml        # Applied to control-plane only
│   ├── join_workers.yaml        # Applied to workers only
│   ├── support_tools.yaml       # Optional extras
│   ├── workstation.yaml         # dev workstation VM
│   ├── nfs_server.yaml          # NFS server VM (run before nfs_setup)
│   ├── vault.yaml               # vault-02 VM: install, configure, seed
│   └── coredns_hosts.yaml       # pins vault.mgryn.cc in cluster CoreDNS
└── roles/
    ├── argocd/
    ├── base_setup/
    ├── workstation/
    ├── containerd/
    ├── nfs_server/
    ├── kube_packages/
    ├── control_plane/
    ├── node_join/
    ├── support_tools/
    ├── vault/
    └── coredns_hosts/
```

This Ansible implementation automates Kubernetes setup of Ubuntu Cluster in Development Environment.

## Requirements

- Ansible ≥ 2.10 (collections not strictly required; add as needed).
- SSH access to each Ubuntu host via the user defined in `ansible.cfg`.
- `sudo` privileges on all nodes.

## Secrets management

Structure:

```txt
host_ips:
  master-01:
  worker-01:
  worker-02:
  claude-code-01:
  nfs-01:

proxmox_vm_ids:
  master-01:
  worker-01:
  worker-02:
  claude-code-01:
  nfs-01:

user_name:
control_plane_endpoint:
nfs_server_ip:
argocd_admin_password_hash:
grafana_admin_password:
harbor_admin_password:          # plus 7 more harbor_* values

vault_kv:
  kv-dev:
    jobboard/db:
      POSTGRES_PASSWORD:
      DATABASE_URL:
      JOBBOARD_SECRET:
    jobboard/ghcr:
      username:
      token:
      dockerconfigjson:          # read by argocd/apps/jobboard/base/ghcr-secret.yaml
```

See `secret.yaml.example` for the annotated shape, including how
`dockerconfigjson` is assembled.

`vault_kv` is not read directly by anything in the cluster. It is the seed:
top-level keys are Vault mounts (must be in `vault_kv_mounts`), and
`roles/vault/tasks/seed.yaml` writes each path under its mount into Vault's
KV v2 store, writing a path only when its value differs from what is
already there. From `kv-dev/jobboard/db` and `kv-dev/jobboard/ghcr`,
argocd-vault-plugin resolves `<path:kv-dev/data/jobboard/...#FIELD>`
placeholders in the committed jobboard manifests at ArgoCD sync time. The
vault of record for a running secret is Vault, not `secret.yaml` — this
block only exists so a lost or resealed Vault can be re-seeded from
something already backed up in the password manager.

**Vault's root token is never stored anywhere in this repository**, not
even encrypted. Any playbook run that talks to Vault takes it per-invocation
with `-e vault_token=...`, typed from the password manager, and it never
touches disk.

`argocd_admin_password_hash` is a bcrypt hash, not a password, and the
plaintext belongs in a password manager. ArgoCD uses Go's bcrypt, which
accepts `$2a$` and `$2b$` but rejects the `$2y$` that `htpasswd` emits --
hence the `sed` below. Use whichever tool you have:

```bash
htpasswd -nbBC 10 "" 'thepassword' | tr -d ':\n' | sed 's/$2y/$2a/'
python3 -c "import bcrypt;print(bcrypt.hashpw(b'thepassword',bcrypt.gensalt(10)).decode())"
argocd account bcrypt --password 'thepassword'
docker run --rm httpd:alpine htpasswd -nbBC 10 "" 'thepassword' | tr -d ':\n' | sed 's/$2y/$2a/'
``` The `argocd` role asserts it is
present and starts with `$2a$` before running Helm, because an unset value
makes the chart fall back to a random password in `argocd-initial-admin-secret`
-- which looks like a successful install right up until you try to log in.

All sensitive information lives in ansible/secret.yaml, encrypted with Ansible Vault.

1. Create or edit the secrets file

```bash
cd ansible
ansible-vault create secret.yaml   # or `ansible-vault edit secret.yaml`
```

3. Vault password
   • Prompt each run with `--ask-vault-pass`

4. Editing later

```bash
ansible-vault edit secret.yaml
ansible-vault view secret.yaml
```

## Usage

From the `.ansible` directory:

1. **Bootstrap everything (common prep, control plane, and worker join):**

```bash
ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass
```

2. **Re-run control-plane initialization only (after a reset or rebuild):**

```bash
ansible-playbook playbooks/cluster_init.yaml -e @secret.yaml --ask-vault-pass
```

3. **Join workers (e.g., after adding new nodes):**

```bash
ansible-playbook playbooks/join_workers.yaml -e @secret.yaml --ask-vault-pass
```

4. Optional helper tooling (kubectl aliases, etc.):
   Set `support_tools_enabled: true` in group_vars/all.yaml.
   Run:

```bash
ansible-playbook playbooks/support_tools.yaml -e @secret.yaml --ask-vault-pass
```

5. **Provision the NFS server, then the cluster clients:**

   Terraform creates the VM (`terraform/environments/shared`, module `nfs`);
   these playbooks format, mount and export its `nfs-dev`, `nfs-prod` and
   `nfs-backups` disks and install `nfs-common` on the nodes. `nfs-01` is in
   `inventories/shared`, not the default dev inventory.
   Add `nfs-01` to `host_ips` / `proxmox_vm_ids` and set `nfs_server_ip`
   in `secret.yaml` first. Order matters -- the client role's `showmount`
   check reports the server unreachable if it has not been exported yet.

```bash
ansible-playbook -i inventories/shared playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
ansible-playbook playbooks/nfs_setup.yaml  -e @secret.yaml --ask-vault-pass
```

6. **Provision the workstation VM:**

   Terraform creates the VM (`terraform/environments/dev`, module
   `claude_code`); this playbook installs the toolchain: Claude Code, Node,
   Docker, uv, kubectl, kustomize, terraform, ansible-lint and pre-commit.
   Add `claude-code-01` to the `host_ips` and `proxmox_vm_ids` maps in
   `secret.yaml` first.

```bash
ansible-playbook playbooks/workstation.yaml -e @secret.yaml --ask-vault-pass
```

   Authentication is not automated. SSH in once and run `claude` to complete
   the interactive login; no API key is stored in the vault or in tfstate.

7. **Install, seed and configure Vault:**

   Terraform creates the VM (`terraform/environments/shared`, module
   `vault-vm`, `vault-02`); this playbook targets the `vault` group,
   which lives in `inventories/shared`. Install and TLS need only that
   inventory:

   ```bash
   ansible-playbook -i inventories/shared playbooks/vault.yaml -e @secret.yaml --ask-vault-pass
   ```

   Configure reaches each cluster's control plane, in `inventories/dev`,
   so it needs both, and it must run once `argocd-config` has synced
   `argocd/base/` and created the `vault-auth-token` Secret -- configure
   reads it:

   ```bash
   ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml \
     -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=true \
     -e vault_token=<root token>
   ```

   `vault_seed` replays `vault_kv` from `secret.yaml` into the mounts it
   names, writing a path only when its value has changed.
   `vault operator init` and every unseal on `vault-02` stay manual --
   see `docs/rebuild.md`.

   **`vault_token` is passed with `-e` on the command line for that one
   run and never stored** -- not in `secret.yaml`, not anywhere else in
   this repository.

   **Troubleshooting the k8s-auth step.** k8s auth runs under
   `-e vault_configure=true` with both inventories (see item 7 above). The
   task that posts `auth/kubernetes/config` is `no_log: true` -- its request
   body carries the root token, the token-reviewer JWT and the cluster CA
   all at once, and there is no way to hide one without hiding all three. A
   failure there shows only `the output has been hidden due to the fact
   that 'no_log: true'`, which tells you nothing. Diagnose it by hand
   instead: query the same endpoint directly with the root token,

   ```bash
   curl -s --cacert ~/.homelab-ca/ca.crt --header "X-Vault-Token: $VAULT_TOKEN" \
     https://vault.mgryn.cc:8200/v1/auth/kubernetes/config | jq .
   ```

   and compare against what the task tried to send. Vault does not return
   `token_reviewer_jwt` on read -- only `kubernetes_host`,
   `kubernetes_ca_cert`, `pem_keys`, `issuer` and the `disable_*` flags come
   back -- so check those against what was sent. The real error is almost
   always an empty or stale reviewer JWT, which the preceding task's own
   `assert` catches before this one runs, or a `kubernetes_host` that does
   not match `host_ips['master-01']`.

8. **Pin `vault.mgryn.cc` in the cluster's CoreDNS:**

   Ansible owns this pin, never ArgoCD: a `hosts` block mapping
   `vault-02`'s IP to `vault.mgryn.cc` in the `coredns` ConfigMap, then a
   restart of the CoreDNS Deployment. Re-run it after every kubeadm
   upgrade, which can rewrite the ConfigMap and drop the block.

   ```bash
   ansible-playbook playbooks/coredns_hosts.yaml -e @secret.yaml --ask-vault-pass
   ```
