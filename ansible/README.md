# Ansible

Configures what Terraform builds: the kubeadm dev cluster's OS and packages,
the NFS server, `vault-02`, the LAN service LXCs, the workstation VM, and
ArgoCD on the Talos prod cluster. The commands to run each playbook, and what
to expect, are in
[docs/runbooks/playbooks-and-terraform.md](../docs/runbooks/playbooks-and-terraform.md)
([ADR 0025](../docs/decisions/0025-runbooks-own-operator-commands.md));
the order for a full rebuild is [docs/rebuild.md](../docs/rebuild.md).

## Layout

```txt
ansible/
├── ansible.cfg
├── requirements.yml        # collections the roles and playbooks need
├── secret.yaml             # ansible-vault, committed encrypted
├── secret.yaml.example     # the annotated shape of secret.yaml
├── inventories/
│   ├── dev/                # kubeadm cluster and the workstation VM (default)
│   │   ├── hosts.yaml
│   │   └── group_vars/
│   ├── shared/             # nfs-01, vault-02 and the LAN LXCs (-i)
│   └── prod/               # the Talos prod cluster (-i)
├── playbooks/
│   ├── site.yaml           # kubeadm: OS prep, control plane, worker join
│   ├── cluster_init.yaml   # control-plane init only
│   ├── join_workers.yaml   # worker join only
│   ├── dev_register.yaml   # register dev with the prod hub's ArgoCD
│   ├── argocd-prod.yaml    # ArgoCD on the prod cluster
│   ├── coredns_hosts.yaml  # pin vault.mgryn.cc in cluster CoreDNS
│   ├── nfs_server.yaml     # nfs-01 (before nfs_setup)
│   ├── nfs_setup.yaml      # nfs-common on the dev nodes
│   ├── vault.yaml          # vault-02: install, TLS, seed, configure
│   ├── lan_services.yaml   # pihole, traefik, glance, gatus, orangutan
│   ├── support_tools.yaml  # optional helpers on the control plane
│   └── workstation.yaml    # toolchain on claude-code-01
└── roles/
    ├── base_setup  containerd  kube_packages  control_plane  node_join
    ├── coredns_hosts  nfs_server  nfs_client  support_tools  workstation
    ├── argocd  vault
    └── pihole  traefik  glance  gatus  orangutan
```

## Requirements

- Ansible, and the collections in `requirements.yml`:
  `ansible-galaxy collection install -r ansible/requirements.yml`.
- SSH access to each host as the user and key named in `secret.yaml`
  (`user_name`, `ssh_private_key`), and `sudo` on the hosts.
- `ansible-lint` runs at profile `production` with no ignore file
  ([ADR 0009](../docs/decisions/0009-ci-reads-only-lint-blocks.md)).

## Secrets

Everything sensitive lives in `ansible/secret.yaml`, encrypted with Ansible
Vault and passed with `-e @secret.yaml --ask-vault-pass`. Create or edit it
with `ansible-vault create|edit secret.yaml`. `secret.yaml.example` is the
annotated shape; its top-level blocks are:

- `host_ips` and `proxmox_vm_ids`: the address and vmid of every host, keyed
  by the inventory host name. Nothing else in the repository records them.
- `user_name`, `ssh_private_key`, `control_plane_endpoint`, `nfs_server_ip`.
- `argocd_admin_password_hash`, a bcrypt hash and not a password.
- `vault_kv`: the seed for Vault, see below.
- One block of credentials per LAN service (Pi-hole, Traefik, Gatus, Glance,
  Orangutan).

Losing the vault password loses the file. Keep it in a password manager.

**`vault_kv` is a seed, not a live secret.** Top-level keys are Vault mounts
(`kv-dev`, `kv-prod`, listed in `vault_kv_mounts`).
`roles/vault/tasks/seed.yaml` writes each path into Vault's KV v2 store,
only when its value differs from what is there. argocd-vault-plugin then
resolves `<path:kv-<env>/data/...#FIELD>` placeholders against Vault at sync
time. The vault of record for a running secret is Vault; the block exists so
a lost or resealed Vault can be re-seeded.

**Vault's root token is never stored in the repository**, not even
encrypted. Any run that talks to Vault takes it with `-e vault_token=...`,
typed from the password manager, for that one run.

**`argocd_admin_password_hash` must start with `$2a$` or `$2b$`.** ArgoCD's
Go bcrypt rejects `$2y$`. Generate it with the `argocd` CLI, which needs no
login:

```bash
argocd account bcrypt --password 'thepassword'
```

The `argocd` role asserts the value before running Helm: an unset value makes
the chart fall back to a random password in `argocd-initial-admin-secret`,
which looks like a successful install until the first login.

## Troubleshooting the Vault Kubernetes-auth step

The task that posts `auth/kubernetes/config` is `no_log: true`: its body
carries the root token, the token-reviewer JWT and the cluster CA at once,
and one cannot be hidden without hiding all three. A failure shows only
`the output has been hidden due to the fact that 'no_log: true'`. Query the
same endpoint by hand instead:

```bash
curl -s --cacert ~/.homelab-ca/ca.crt --header "X-Vault-Token: $VAULT_TOKEN" \
  https://vault.mgryn.cc:8200/v1/auth/kubernetes/config | jq .
```

Vault does not return `token_reviewer_jwt` on read; check `kubernetes_host`,
`kubernetes_ca_cert`, `pem_keys`, `issuer` and the `disable_*` flags against
what was sent. The usual cause is an empty or stale reviewer JWT, which the
preceding task's `assert` catches first, or a `kubernetes_host` that does not
match the cluster's control-plane address.
