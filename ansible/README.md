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
│   ├── claude_code.yaml         # Claude Code workstation VM
│   └── nfs_server.yaml          # NFS server VM (run before nfs_setup)
└── roles/
    ├── argocd/
    ├── base_setup/
    ├── claude_code/
    ├── containerd/
    ├── nfs_server/
    ├── kube_packages/
    ├── control_plane/
    ├── node_join/
    └── support_tools/
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
```

See `secret.yaml.example` for the annotated shape.

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

   Terraform creates the VM (`proxmox/environments/dev`, module `nfs`);
   these playbooks export the share and install `nfs-common` on the nodes.
   Add `nfs-01` to `host_ips` / `proxmox_vm_ids` and set `nfs_server_ip`
   in `secret.yaml` first. Order matters -- the client role's `showmount`
   check reports the server unreachable if it has not been exported yet.

```bash
ansible-playbook playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
ansible-playbook playbooks/nfs_setup.yaml  -e @secret.yaml --ask-vault-pass
```

6. **Provision the Claude Code workstation VM:**

   Terraform creates the VM (`proxmox/environments/dev`, module `claude_code`);
   this playbook installs the toolchain on it. Add `claude-code-01` to the
   `host_ips` and `proxmox_vm_ids` maps in `secret.yaml` first.

```bash
ansible-playbook playbooks/claude_code.yaml -e @secret.yaml --ask-vault-pass
```

   Authentication is not automated. SSH in once and run `claude` to complete
   the interactive login; no API key is stored in the vault or in tfstate.
