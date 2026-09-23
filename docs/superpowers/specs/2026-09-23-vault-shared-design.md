# Shared Vault — Design

Move `vault-01` out of the dev environment into `proxmox/environments/shared`,
make the `vault` Ansible role able to configure more than one cluster's
Kubernetes auth, and namespace dev's KV paths under `secret/dev/` so a future
prod cluster can share the same Vault without being able to read dev's
secrets, or dev prod's.

## Problem

`vault-01` (vmid 104) is declared in `proxmox/environments/dev/main.tf` and
listed in `ansible/inventories/dev`. `proxmox/environments/prod/main.tf`
declares a *second* Vault, `vault_lxc` (vmid 333), which has never been
applied. Making prod live would therefore either stand up a duplicate root of
trust or leave prod depending on a machine dev's `terraform apply` owns.

Three consequences:

**Two Vaults means two of everything that hurts.** Each has its own unseal key
and root token, and each comes back sealed after a reboot — a state that looks
healthy, because Argo's health field stays green while AVP renders nothing.
The host died unattended on 2026-09-10; doubling that ritual doubles the ways
a quiet failure survives a power loss. The Cloudflare API token cert-manager
needs would also live in both, and rotate twice.

**One Vault, as configured today, has no isolation.** The `argocd-read` policy
grants `read` on `secret/data/*` — every secret in the store. Adding prod's
secrets beside dev's would let either cluster read the other's.

**The role hard-codes one cluster.** `roles/vault/tasks/k8s_auth.yaml` names
the `kubernetes` auth mount, `host_ips['master-01']`, the `argocd-read` policy
and the `argocd` role as literals.

## Decisions

| Question | Decision |
| --- | --- |
| One Vault or two | One, shared, in `proxmox/environments/shared` |
| Prod's `vault_lxc` (333) | Deleted from the scaffolding, never built |
| Isolation | Namespace both: `secret/dev/*` and, later, `secret/prod/*` |
| Prod's auth mount, policy, paths | Deferred to the prod-cluster project |
| Landing | Two PRs: the move, then the path cutover |

Prod is scaffolding that has never been applied. This design touches it only
to delete the duplicate Vault.

## Terraform

### `proxmox/environments/shared/`

Gains `module "vault"`, copied from the dev block unchanged — `modules/lxc`
already builds it, so no new module:

- vmid 104, pool `LXC`, `unprivileged = true`, no `features` block
- 1 core, 1024 MB, swap 0, 8G rootfs on `local-lvm`
- `network_ip = var.vault_lxc_ip`, gateway from `var.gateway`
- `start = true`, `start_at_node_boot = true`, `startup = "order=5,up=20"` —
  ahead of `nfs-01` at order 10, because every Application carrying a
  `<path:...>` placeholder fails to sync without Vault
- the existing comments move with it, including why no `nesting` is set

New variables in the shared root: `debian_os_template`, `lxc_pass`,
`vault_lxc_ip`, each added to `shared.tfvars.example`.

```hcl
import {
  to = module.vault.proxmox_lxc.lxc_container
  id = "${var.pm_target_node}/lxc/104"
}
```

Removed in a follow-up commit once applied, exactly as the NFS import was: on
a rebuilt host vmid 104 does not exist and the import fails the plan. The PR
does not merge while the block is present.

### `proxmox/environments/dev/`

`module "vault"` and the `vault_lxc_ip` variable are deleted, the
`dev.tfvars.example` line with them, and:

```hcl
removed {
  from = module.vault
  lifecycle {
    destroy = false
  }
}
```

### `proxmox/environments/prod/`

`module "vault_lxc"` (vmid 333), its `vault_ip` variable and the
`prod.tfvars.example` line are deleted.

### Apply gates

1. **dev plan** — one resource released from state without being destroyed,
   nothing else changed by this diff. Apply.
2. **shared plan** — 1 import, in-place only, **0 to destroy, no
   replacement**. Apply.

If the provider demands a restart of the container, stop. `modules/lxc` does
not set `automatic_reboot`, and Vault is the root of trust for every app with
a placeholder. Decide deliberately, as with the NFS disks — where the same
refusal was resolved by making the change on the host and letting Terraform
reconcile.

## Ansible

### Inventory

The `vault` group moves from `inventories/dev/hosts.yaml` to
`inventories/shared/hosts.yaml`, keeping its `ansible_user: root` override:
the Debian LXC template has no `ubuntu` account, and without the override the
play fails at the connection. `playbooks/vault.yaml` is unchanged and runs
with `-i inventories/shared`.

`inventories/prod/hosts.yaml` loses its `vault` group and `vault-lxc` host.

**Two inventories on one run.** `k8s_auth.yaml` delegates the CA and
token-reviewer reads to a control-plane host, which lives in
`inventories/dev`. Once Vault is in `inventories/shared`, a run that
configures auth needs both: `-i inventories/shared -i inventories/dev`.
Runs that only install or seed need the shared inventory alone. The prod
cluster later adds `-i inventories/prod` for its own entry.

### The role becomes multi-cluster

`roles/vault/defaults/main.yaml` gains a list, and the tasks loop over it:

```yaml
vault_kv_prefix: dev

vault_k8s_clusters:
  - name: dev
    auth_path: kubernetes
    api_host: "{{ host_ips['master-01'] }}"
    control_plane_host: master-01
    policy_name: argocd-read
    role_name: argocd
    service_account_names: ["argocd-repo-server"]
    service_account_namespaces: ["argocd"]
```

Only dev exists, so the list has one entry. The prod entry
(`auth_path: kubernetes-prod`, `policy_name: argocd-read-prod`, its own API
host) is added by the prod-cluster project, against an API server that exists
to be configured.

In `tasks/k8s_auth.yaml`, every literal becomes an `item` field:
`sys/auth/{{ item.auth_path }}`, `auth/{{ item.auth_path }}/config`,
`sys/policies/acl/{{ item.policy_name }}`,
`auth/{{ item.auth_path }}/role/{{ item.role_name }}`. The CA and
token-reviewer JWT reads become `delegate_to: "{{ item.control_plane_host }}"`
instead of the fixed control-plane delegation.

Dev's mount path, policy name and role name are unchanged, so the AVP config
and its Secret are untouched.

### The policy is scoped

```hcl
path "secret/data/{{ item.name }}/*"     { capabilities = ["read"] }
path "secret/metadata/{{ item.name }}/*" { capabilities = ["list", "read"] }
```

Replacing today's `secret/data/*`. Dev cannot read `secret/prod/*`, and prod
will not be able to read dev's.

**Order matters.** The narrowed policy ships in PR 1 but must not be applied
until the manifests point at `secret/dev/*`. `vault_seed` and
`vault_configure_k8s_auth` are separate flags, so PR 1's runs seed without
touching the policy; a run with `vault_configure_k8s_auth: true` before the
cutover would revoke dev's access to the paths its manifests still name.

### Seeding keeps `secret.yaml` as it is

`tasks/seed.yaml` writes each `vault_kv` key under `vault_kv_prefix`, so the
encrypted `secret.yaml` needs no edit and prod later seeds with its own
prefix. The three dev paths become:

| Now | After |
| --- | --- |
| `secret/cert-manager/cloudflare` | `secret/dev/cert-manager/cloudflare` |
| `secret/jobboard/db` | `secret/dev/jobboard/db` |
| `secret/jobboard/ghcr` | `secret/dev/jobboard/ghcr` |

## Manifests

Five placeholders across three files:

- `argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml` —
  `<path:secret/data/dev/cert-manager/cloudflare#API_TOKEN>`
- `argocd/apps/jobboard/base/secret.yaml` — three placeholders under
  `secret/data/dev/jobboard/db`
- `argocd/apps/jobboard/base/ghcr-secret.yaml` —
  `<path:secret/data/dev/jobboard/ghcr#dockerconfigjson>`

The two jobboard files **move from `base/` into the `dev/` overlay**, and the
dev `kustomization.yaml` gains them as resources. A `dev`-prefixed path in a
base that a prod overlay would also consume defeats the namespacing; keeping
base env-agnostic is what makes the scheme hold.

## Cutover

Copy first, delete last. Any other order leaves a window where placeholders
resolve to nothing and every app carrying one reports `ComparisonError` while
its last-applied resources sit there looking healthy.

1. Re-run `playbooks/vault.yaml` with seeding enabled and
   `vault_kv_prefix: dev`. Old and new paths now both exist.
2. Merge the manifest PR. ArgoCD syncs; AVP resolves the new paths.
3. Verify: the three apps `Synced`, and their Secrets in the cluster hold real
   values, not empty strings.
4. Apply the narrowed policy (re-run with `vault_configure_k8s_auth: true`),
   then re-verify a sync.
5. Delete the old KV paths: `vault kv metadata delete secret/cert-manager/cloudflare`,
   and the same for `secret/jobboard/db` and `secret/jobboard/ghcr`.

## Documentation

- `CLAUDE.md` — Layout: `environments/shared/` holds `nfs-01` and `vault-01`.
  The sealed-Vault bullet: one Vault now serves both clusters, so a seal stops
  both. The secrets section: KV paths are namespaced per environment, and the
  placeholder form is `<path:secret/data/<env>/...>`.
- `docs/rebuild.md` — the `shared` apply creates Vault as well as NFS and must
  precede the dev cluster (order 5 before NFS at 10); `playbooks/vault.yaml`
  runs with `-i inventories/shared`; the LXC-template blocker now belongs to
  the shared root, not dev.
- `ansible/README.md`, `proxmox/README.md` — where Vault lives and which
  inventory reaches it.

## Verification

- `terraform fmt -check`, `validate` and `tflint` on `dev` and `shared`;
  `ansible-lint`; `playbooks/vault.yaml --syntax-check -i inventories/shared`;
  `pre-commit run --all-files`; `scripts/check-manifests.sh`.
- The apply gates above.
- After the move: `vault status` on `vault-01` (unsealed), the three dev apps
  still `Synced`, `pct config 104` unchanged apart from the tag.
- After the cutover: `vault kv get secret/dev/jobboard/db` matches what the old
  path held; the three apps' Secrets in the cluster hold real values;
  `vault kv get secret/dev/...` succeeds with dev's token while a read outside
  `secret/dev/*` is denied; `vault-01` reboots, comes back sealed as always, is
  unsealed by hand, and the apps recover.

## Landing

Two PRs, each one logical change:

1. **The move** — Terraform, inventory, the multi-cluster role, prefixed
   seeding, prod's 333 deleted, docs. Dev's behaviour does not change: the old
   paths still exist and the old policy still grants them.
2. **The cutover** — the three manifests (two moving to the dev overlay), the
   narrowed policy, and the operator steps that seed, verify and delete.

Between them the system is stable, which is why they are separate.

## Out of scope

- The prod cluster, its auth mount, its policies and its secrets.
- Retiring `ubuntu` (100) and `ubuntu-2` (101) to free the 12 GiB prod needs.
- Vault HA, auto-unseal, or a storage backend other than `file`.
- Backups of Vault's data.
