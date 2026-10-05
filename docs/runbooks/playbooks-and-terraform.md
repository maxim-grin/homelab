# Playbooks and Terraform

Conventions (working directory, `$DEV_KC`, `$PROD_KC`, Vault token handling)
are in [README.md](README.md). Terraform and Ansible run from the operator's
workstation, never from the cluster.

## Terraform

Three roots, each with its own gitignored `<env>.tfvars` and local state:

| Root                           | Var file         | Holds                                      |
| ------------------------------ | ---------------- | ------------------------------------------ |
| `terraform/environments/dev`   | `dev.tfvars`     | the kubeadm cluster, `claude-code-01`      |
| `terraform/environments/shared`| `shared.tfvars`  | `nfs-01`, `vault-02`, the LAN LXCs         |
| `terraform/environments/prod`  | `prod.tfvars`    | the Talos cluster                          |

`*.tfvars` carry the Proxmox API token and cloud-init password. They are
gitignored and have no backup; copy from `<env>.tfvars.example` on a rebuild
([backups-and-recovery.md](backups-and-recovery.md)). Prod's state, with the
Talos PKI, exists only in `environments/prod/terraform.tfstate`.

### Plan and apply an environment

When: any change under `terraform/`. Plan first, read the summary, then apply.
Replace `dev` with `shared` or `prod`.

```bash
cd terraform/environments/dev
terraform init
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

Expect: the plan ends `Plan: N to add, N to change, 0 to destroy.` with
exactly the counts you intended; apply ends `Apply complete!`.

If not: any `destroy` you did not intend is a stop, not a warning. A renamed
module or resource reads as destroy and create; add a `moved` block
([ADR 0013](../decisions/0013-terraform-renames-need-moved-blocks.md)).
CI runs `validate`, not `plan`, so nothing else catches it.

### Repair state after a failed apply

When: a disk shrink failed with `can't unplug bootdisk 'scsi0'`, or state
drifted from Proxmox. `disk_size` only goes up; the failed attempt still wrote
the smaller value into state. First restore the real value in the module, then
resync state from the API without touching infrastructure.

```bash
cd terraform/environments/dev
terraform apply -refresh-only -var-file=dev.tfvars
```

Expect: state shows the size Proxmox has; a following `plan` shows no change.

If not: [rebuild.md](../rebuild.md) covers growing a disk (`growpart`,
`resize2fs`) and replacing a VM with `-replace`.

### Resize a node

When: you changed `memory` (or cores) of a VM and applied. The `talos-node`,
`nfs-server` and `vault-vm` modules (Talos nodes, `nfs-01`, `vault-02`) set
`automatic_reboot = false`, so the apply ends with the VM "needs to be
rebooted" and keeps the old size until restarted. The dev VMs (`ubuntu-vm`,
`ubuntu-k8s` modules) do not set it and follow the provider default, so they
may reboot during the apply itself: drain a dev node before applying. One node
at a time; for a cluster node `kubectl drain` first and `kubectl uncordon`
after. `<vmid>` is
the node's vmid, in `ansible/secret.yaml` under `proxmox_vm_ids`; run on `pve`.

```bash
qm reboot <vmid>
```

Expect: the node returns and reports the new size. For Talos, a guest-level
`talosctl reboot` does not pick up the new size; use `qm reboot`.

If not: `qm status <vmid>`; see [checks.md](checks.md) for host checks.

## Playbooks

Run from `ansible/` with `-e @secret.yaml --ask-vault-pass`. The default
inventory is `inventories/dev`; `shared` and `prod` runs need `-i`.

| Playbook              | Inventory flag                                | Required `-e` vars                                                       | When                                                         |
| --------------------- | --------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `site.yaml`           | default (dev)                                 | none                                                                     | build the kubeadm cluster: OS prep, control plane, join      |
| `cluster_init.yaml`   | default (dev)                                 | none                                                                     | redo control-plane init after a reset                        |
| `join_workers.yaml`   | default (dev)                                 | none                                                                     | add workers, always with `cluster_init.yaml` in one run      |
| `cluster_secrets.yaml`| default (dev)                                 | none                                                                     | apply out-of-band cluster Secrets                            |
| `argocd-dev.yaml`     | default (dev)                                 | none                                                                     | install or re-run ArgoCD on dev                              |
| `argocd-prod.yaml`    | none (runs on localhost)                      | `prod_kubeconfig=<mode 600 file>`                                        | install or re-run ArgoCD on prod                             |
| `coredns_hosts.yaml`  | default (dev)                                 | none                                                                     | pin `vault.mgryn.cc` in CoreDNS; after every kubeadm upgrade|
| `nfs_server.yaml`     | `-i inventories/shared`                       | none                                                                     | provision `nfs-01`, before `nfs_setup.yaml`                  |
| `nfs_setup.yaml`      | default (dev)                                 | none                                                                     | `nfs-common` on the dev nodes, after `nfs_server.yaml`       |
| `vault.yaml`          | `-i inventories/shared` (+ `-i inventories/dev` for dev configure) | none for install; seed, configure dev and configure prod each take their own set of `vault_seed`, `vault_configure`, `vault_token`, `vault_k8s_cluster_names`, `vault_prod_kubeconfig` (see [Vault playbook](#vault-playbook)) | install, seed, configure `vault-02` |
| `lan_services.yaml`   | `-i inventories/shared`                       | none; `--limit <service>` for one                                        | the LAN LXCs, see [LAN services](#lan-services)              |
| `support_tools.yaml`  | default (dev)                                 | none; `support_tools_enabled: true` in `group_vars/all.yaml`             | kubectl aliases and helpers on the control plane             |
| `workstation.yaml`    | default (dev)                                 | none                                                                     | toolchain on `claude-code-01`                                |

Order for a full rebuild is in [rebuild.md](../rebuild.md). Each block below:
Expect is the end of the play recap with `failed=0`; If not, re-run with `-v`
and read the failing task, or see the role named in the play.

### Build the kubeadm cluster

When: first build of dev, or after Terraform recreated the VMs. `site.yaml`
runs OS prep, control plane init and the worker join in one invocation.

```bash
ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0` on every host. If not: [rebuild.md](../rebuild.md) step
"kubeadm cluster".

### Re-run control-plane init and the worker join

When: control plane reset, or new workers. The join command exists only for
the length of one run (`set_fact` in the control-plane play), so
`join_workers.yaml` alone always fails: pass both playbooks to one invocation.

```bash
ansible-playbook playbooks/cluster_init.yaml playbooks/join_workers.yaml \
  -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0`; workers show `Ready` in `kubectl get nodes`. If not: see
[checks.md](checks.md).

### Apply out-of-band cluster Secrets

When: after ArgoCD is up on a fresh dev cluster; these Secrets are not in git.

```bash
ansible-playbook playbooks/cluster_secrets.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0`. If not: values come from `ansible/secret.yaml`.

### Deploy ArgoCD to dev

When: first install, or to change the dev ArgoCD settings (host
`dev-argocd.mgryn.cc`). The role needs the `cmp-plugin` ConfigMap and AVP
Secret first; the role creates them before Helm runs.

```bash
ansible-playbook playbooks/argocd-dev.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0`; `kubectl --kubeconfig "$DEV_KC" -n argocd get pods` all
`Running` or `Completed`. If not: `repo-server` stuck in `Init` means the AVP
ConfigMap or Secret is missing ([checks.md](checks.md)).

### Deploy ArgoCD to prod

When: first prod bootstrap, or to re-run after the platform PR merges (the
Ingress `letsencrypt-prod` annotation comes from this playbook). It runs on the
operator's workstation against the cluster API and needs Helm and the python
`kubernetes` package locally. The kubeconfig comes from Terraform into a
mode 600 temp file, never kept on disk. `PROD_TMP` here is that temp file, not the README-convention `$PROD_TMP` path. The
play does not apply `argocd/base/projects.yaml` or the app-of-apps; apply
those by hand afterwards.

```bash
cd terraform/environments/prod
umask 077; PROD_TMP="$(mktemp)"
terraform output -raw kubeconfig > "$PROD_TMP"
cd ../../../ansible
ansible-playbook playbooks/argocd-prod.yaml -e @secret.yaml \
  -e prod_kubeconfig="$PROD_TMP" --ask-vault-pass
kubectl --kubeconfig "$PROD_TMP" -n argocd get pods
rm "$PROD_TMP"
```

Expect: pods `Running` or `Completed`, `repo-server` not in `Init`. If not:
the play fails fast without `prod_kubeconfig`, a missing file, Helm or the
python package; [rebuild.md](../rebuild.md) "Bootstrap the prod hub".

### Pin names in CoreDNS

When: after every kubeadm upgrade (it can rewrite the ConfigMap), and once
when `vault.mgryn.cc` is first needed in-cluster.

```bash
ansible-playbook playbooks/coredns_hosts.yaml -e @secret.yaml --ask-vault-pass
kubectl --kubeconfig "$DEV_KC" run -it --rm dnscheck --image=busybox:1.36 --restart=Never -- nslookup vault.mgryn.cc
```

Expect: the lookup answers `10.0.0.133`. If not: re-run the playbook; check
`coredns_hosts_entries` in the role.

### Provision NFS

When: build or repair `nfs-01`. Server first: the client role's `showmount`
check reports the server unreachable until it is exported. `nfs-01` must be in
`host_ips` and `proxmox_vm_ids` in `secret.yaml`, with `nfs_server_ip` set.

```bash
ansible-playbook -i inventories/shared playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
ansible-playbook playbooks/nfs_setup.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0` on both; `showmount -e` on a node lists the exports. If not:
the server refuses to mount over a non-empty directory and will not start until
all three disks are mounted ([checks.md](checks.md) NFS).

### Install support tools and the workstation

When: `support_tools.yaml` needs `support_tools_enabled: true` in
`group_vars/all.yaml`. `workstation.yaml` needs `claude-code-01` in `host_ips`
and `proxmox_vm_ids` in `secret.yaml`; the Claude login stays interactive.

```bash
ansible-playbook playbooks/support_tools.yaml -e @secret.yaml --ask-vault-pass
ansible-playbook playbooks/workstation.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0`. If not: read the failing task; no secret is stored for the
Claude login.

## Vault playbook

`vault.yaml` targets the `vault` group (`vault-02`), which lives in
`inventories/shared`. Its jobs differ in inventory and variables. Where a
command needs the root token, read it without echo so it stays out of shell
history (`<root token>` in the older docs). Each block below prompts for it
and unsets it, so blocks run independently.

### Install and TLS

When: first build of `vault-02`, or to renew config and TLS. Install the
collections first on a new workstation.

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventories/shared playbooks/vault.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0`. If not: `vault status` on `vault-02` (a restart seals it);
[checks.md](checks.md).

### Seed

When: fill `kv-dev/` and `kv-prod/` from the `vault_kv` block of
`ansible/secret.yaml`, with `vault_configure` left false (the prod-only seed).
`VAULT_TOKEN` is the root token. The play also re-runs install, TLS and
service tasks, which are idempotent, but a service restart seals Vault.

```bash
read -rs VAULT_TOKEN
ansible-playbook -i inventories/shared playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_seed=true \
  -e vault_token="$VAULT_TOKEN"
unset VAULT_TOKEN
```

Expect: `failed=0`; `vault status` on `vault-02` still unsealed. If not:
unseal, see [access.md](access.md) and [checks.md](checks.md).

### Configure dev

When: after `argocd-config` has synced `argocd/base/` and created the
`vault-auth-token` Secret, which configure reads. Dev's control plane is
reached over SSH and lives in `inventories/dev`, so both inventories are
needed. This also seeds.

```bash
read -rs VAULT_TOKEN
ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=true \
  -e vault_token="$VAULT_TOKEN" -e '{"vault_k8s_cluster_names":["dev"]}'
unset VAULT_TOKEN
```

Expect: `failed=0`; placeholder Applications leave `Unknown` on Argo's next
poll. If not: the `vault-auth-token` Secret missing means `argocd-config` has
not synced yet; wait and re-run.

### Configure prod

When: after prod's `argocd-config` is `Synced` (it creates the `vault-auth`
ServiceAccount and Secret). Prod has no SSH: its reviewer JWT and CA come from
the kubeconfig on the operator's workstation, so `inventories/shared` alone
suffices. The block fetches a fresh mode 600 kubeconfig from Terraform and
removes it afterwards.

```bash
cd terraform/environments/prod
umask 077; PROD_TMP="$(mktemp)"
terraform output -raw kubeconfig > "$PROD_TMP"
cd ../../../ansible
read -rs VAULT_TOKEN
ansible-playbook -i inventories/shared playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_configure=true \
  -e vault_token="$VAULT_TOKEN" \
  -e '{"vault_k8s_cluster_names":["prod"]}' \
  -e vault_prod_kubeconfig="$PROD_TMP"
unset VAULT_TOKEN
rm "$PROD_TMP"
```

Expect: `vault read auth/kubernetes-prod/config` on `vault-02` shows
`kubernetes_host https://10.0.0.110:6443`. If not: [checks.md](checks.md).

## LAN services

`lan_services.yaml` builds the LAN LXCs from `inventories/shared`, in
dependency order: Pi-hole, Traefik, Gatus, Orangutan, Glance. A bootstrap play
first installs Python and requires `1.1.1.1` as the first resolver on each
container; it always applies, even with `--limit`.

### Apply all LAN services

When: first build, or a change that touches several roles.

```bash
ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass
```

Expect: `failed=0` for every container. If not: the resolver check fails when
the first nameserver is not `1.1.1.1`; fix `resolv.conf` on that LXC (never
Pi-hole first).

### Apply one LAN service

When: change one service. `<service>` is a host in `inventories/shared`:
`pihole`, `traefik`, `gatus`, `orangutan` or `glance`.

```bash
ansible-playbook -i inventories/shared playbooks/lan_services.yaml \
  -e @secret.yaml --ask-vault-pass --limit <service>
```

Expect: `failed=0` for the bootstrap and that service's play. If not: see the
service's role under `ansible/roles/`.

## Static checks

When: before every commit and in review; none touches the cluster. Run from
the repo root unless the comment says otherwise. `<role-or-playbook>` and
`<app>` are paths under `ansible/` and `argocd/apps/`. `--syntax-check` and
`ansible-lint` read `secret.yaml`, so they run on the operator's workstation.

```bash
(cd terraform/environments/dev && terraform fmt -check && terraform validate)
(cd ansible && ansible-lint <role-or-playbook>)
(cd ansible && ansible-playbook playbooks/site.yaml --syntax-check -e @secret.yaml --ask-vault-pass)
kustomize build argocd/apps/<app>/dev
pre-commit run --all-files
scripts/check-manifests.sh
scripts/check-runbooks.sh
```

Expect: each exits 0. If not: fix what it names; never bypass a hook with
`--no-verify`. `kustomize build` works on overlays only: Helm values dirs such
as `argocd/apps/ingress-nginx/dev` fail by design, so render those with
`helm template <chart> -f argocd/apps/<app>/dev/values.yaml`.
