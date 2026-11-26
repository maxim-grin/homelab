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

### Pause and resume dev

When: dev's 6 GB goes to prod's workers ([ADR 0034](../decisions/0034-dev-paused-prod-grown.md)).
The VMs are `kubeadm-dev-cp1` (vmid 4101) and `kubeadm-dev-w1` (vmid 4201).
Their disks and the `nfs-dev` data stay. `$PROD_KC` is the prod kubeconfig
([access](access.md)). Run these in order.

**Pause**

1. Dump jobboard's database: [Dump jobboard's database](backups-and-recovery.md#dump-jobboards-database).
2. Merge the pause PR. It removes the `env: dev` entries and
   `argocd/environments/prod/applications/clusters-dev.yaml`. After the merge
   `clusters-dev` is expected to be gone, and the `dev-*` Applications show
   `Unknown`. The set does not delete them.
3. Gate: list the Applications. Do not run step 4 unless both hold.

```bash
kubectl --kubeconfig "$PROD_KC" -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Expect: no `clusters-dev` row, and all eight of `dev-cert-manager`,
`dev-cert-manager-issuers`, `dev-ingress-nginx`, `dev-jobboard`,
`dev-kube-prometheus-stack`, `dev-monitoring-secrets`, `dev-nfs-provisioner`,
`dev-shortener` with SYNC `Unknown`. Otherwise STOP and do not run the loop.
If `clusters-dev` is still listed, the merge has not propagated yet: wait for
ArgoCD's next poll and list again. If a `dev-*` Application still points at
its entry on `main`, the set re-adds the finalizer, and the delete then
cascades into the workloads and the `nfs-dev` data.

4. Delete the eight `dev-*` Applications. Patch the finalizer to `null`, then
   delete, back to back, as in [Retire an app from the set](checks.md#retire-an-app-from-the-set):
   the set's controller puts the finalizer back, so never delete with it in
   place. No cascade: the workloads and `nfs-dev` data stay.

```bash
for app in dev-cert-manager dev-cert-manager-issuers dev-ingress-nginx dev-jobboard \
  dev-kube-prometheus-stack dev-monitoring-secrets dev-nfs-provisioner dev-shortener; do
  kubectl --kubeconfig "$PROD_KC" -n argocd patch application "$app" \
    --type merge -p '{"metadata":{"finalizers":null}}' &&
  kubectl --kubeconfig "$PROD_KC" -n argocd delete application "$app"
done
kubectl --kubeconfig "$PROD_KC" -n argocd get applications
```

Expect: none of the eight, and no `clusters-dev`, in the last listing, and
none back after the next poll. If one comes back, the entry is still on `main`.

5. Stop the dev VMs. Their `start_at_node_boot` is already `false` from the
   pause PR.

```bash
cd terraform/environments/dev
terraform plan -var-file=dev.tfvars
```

Expect `0 to add, 2 to change, 0 to destroy`. Any destroy is a stop. Then
`terraform apply -var-file=dev.tfvars`, and on `pve`:

```bash
qm shutdown 4101
qm shutdown 4201
```

Expect: `qm list` shows both `stopped`.

6. Grow prod. First, on `pve`, run `lvs`: the thin pool must have well over
   60 GB free, since the three disks grow by 20 GB each. If not, STOP. A full
   thin pool gives every guest I/O errors, and a disk cannot be shrunk back.
   Then, in `prod.tfvars`, set both workers to `memory = 7168` (see
   `prod.tfvars.example`). Remove or update any `node_cores` or
   `node_disk_size` override, since the defaults are now 4 and `40G`.

```bash
cd terraform/environments/prod
terraform plan -var-file=prod.tfvars
```

Expect `0 to add, 3 to change, 0 to destroy`. Any destroy is a stop. Then
`terraform apply -var-file=prod.tfvars`. Nothing restarts: the Talos modules
set `automatic_reboot = false`.

7. Roll the prod nodes, one at a time, workers first, then the control plane.
   Order: `3201`, `3202`, `3101`. For each (`<node>` from `kubectl get nodes`,
   `<vmid>` the node's vmid; `drain` for workers only):

```bash
kubectl --kubeconfig "$PROD_KC" drain <node> --ignore-daemonsets --delete-emptydir-data
qm shutdown <vmid>
qm start <vmid>
kubectl --kubeconfig "$PROD_KC" get node <node>
kubectl --kubeconfig "$PROD_KC" uncordon <node>
```

Wait for `Ready` before the next node. A guest reboot does not apply pending
changes, which is why this is `qm shutdown` and `qm start`.

8. Verify:

```bash
kubectl --kubeconfig "$PROD_KC" get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory,DISK:.status.capacity.ephemeral-storage
```

Expect: 4 CPU on all three nodes, about 7 GiB on the workers, and disk near
40 GB. If disk is still near 20 GB, stop: Talos did not grow the partition.
Also expect every `prod-*` Application `Synced` and `Healthy`,
`https://jobs.mgryn.cc/` answering, and `qm list` showing 4101 and 4201
`stopped`.

**Resume** (in this order)

Never `git revert` the pause commit as a whole, and never revert anything
under `terraform/environments/prod/`. The commit also holds prod's
`node_cores` 4 and `node_disk_size` `40G` defaults. Reverting them makes the
next prod apply try to shrink a disk: Proxmox refuses, and Terraform state
then records a size the host does not have. Restore only the files named in
step 4. Every apply below: plan first, and stop on any destroy.

1. Shrink prod's workers. In `prod.tfvars` set both workers back to
   `memory = 4096`, and change nothing else: never disk or cores. Plan,
   apply, then roll the nodes as in step 7. Before applying, check that any
   app added since the pause (directive-copilot, for example) fits in 4 GB
   workers, or retire it first. Otherwise its pods are evicted.
2. Start the dev VMs on `pve`: `qm start 4101` and `qm start 4201`. Expect
   both `running`, and the nodes `Ready` once they join.
3. Run the dev_register playbook, [Register dev with the prod hub](#register-dev-with-the-prod-hub),
   with Vault unsealed (its gate applies). Run it before the restore merge in
   step 4. Skip its `argocd app get clusters-dev` step here: `clusters-dev`
   does not exist until step 4. Its expectations are checked in step 6.
4. Merge the restore PR. It restores exactly these files to their pre-pause
   state, each taken from the commit before the pause (`git checkout <pause-sha>^ -- <file>`),
   unless a later commit changed the file, in which case re-add only the
   entry by hand:
   - `terraform/environments/dev/main.tf`: `start_at_node_boot = true`.
   - `terraform/environments/dev/dev.tftest.hcl`: the boot assertion back to
     `n.start_at_node_boot`, message `both nodes start at node boot`. CI runs
     `terraform test`.
   - the `env: dev` entries in the eight `argocd/apps/*/config.yaml` files
     (`cert-manager`, `cert-manager-issuers`, `ingress-nginx`, `jobboard`,
     `kube-prometheus-stack`, `monitoring-secrets`, `nfs-provisioner`,
     `shortener`).
   - `argocd/environments/prod/applications/clusters-dev.yaml`.
5. Apply dev: `cd terraform/environments/dev`, then
   `terraform plan -var-file=dev.tfvars`. Expect no add and no destroy, with
   `start_at_node_boot` as the change. Any destroy is a stop. Then
   `terraform apply -var-file=dev.tfvars`.
6. Hard-refresh and check, as the end of the [Register dev](#register-dev-with-the-prod-hub)
   entry: `argocd app get clusters-dev --hard-refresh --grpc-web` and
   `argocd cluster list --grpc-web`. The Register expectations differ on
   resume. `clusters-dev` should be Synced and Healthy. The set re-creates the
   `dev-*` Applications from the restored entries, and they sync. `dev` moves
   from `Unknown` ("no applications") to `Successful` once its apps sync. If a
   `dev-*` Application stays on `ComparisonError`, check the Vault seed first.

## Playbooks

Run from `ansible/` with `-e @secret.yaml --ask-vault-pass`. The default
inventory is `inventories/dev`; `shared` and `prod` runs need `-i`.

| Playbook              | Inventory flag                                | Required `-e` vars                                                       | When                                                         |
| --------------------- | --------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `site.yaml`           | default (dev)                                 | none                                                                     | build the kubeadm cluster: OS prep, control plane, join      |
| `cluster_init.yaml`   | default (dev)                                 | none                                                                     | redo control-plane init after a reset                        |
| `join_workers.yaml`   | default (dev)                                 | none                                                                     | add workers, always with `cluster_init.yaml` in one run      |
| `argocd-prod.yaml`    | none (runs on localhost)                      | `prod_kubeconfig=<mode 600 file>`                                        | install or re-run ArgoCD on prod                             |
| `dev_register.yaml`   | `-i inventories/shared -i inventories/dev`    | `vault_token=<root>`                                                     | register dev with the prod hub; after any dev rebuild        |
| `coredns_hosts.yaml`  | default (dev)                                 | none                                                                     | pin `vault.mgryn.cc` in CoreDNS; after every kubeadm upgrade|
| `nfs_server.yaml`     | `-i inventories/shared`                       | none                                                                     | provision `nfs-01`, before `nfs_setup.yaml`                  |
| `nfs_setup.yaml`      | default (dev)                                 | none                                                                     | `nfs-common` on the dev nodes, after `nfs_server.yaml`       |
| `vault.yaml`          | `-i inventories/shared` | none for install; seed, configure dev and configure prod each take their own set of `vault_seed`, `vault_configure`, `vault_token`, `vault_k8s_cluster_names`, `vault_prod_kubeconfig` (see [Vault playbook](#vault-playbook)) | install, seed, configure `vault-02` |
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

### Register dev with the prod hub

Dev is paused ([ADR 0034](../decisions/0034-dev-paused-prod-grown.md)), so
this runs only on resume, in [Pause and resume dev](#pause-and-resume-dev).
The text below describes it as it runs with dev up.

When: after any dev rebuild (a new cluster has a new CA and token, so the
old ones in Vault are stale), and once when dev first becomes a spoke. It
creates the `argocd-manager` ServiceAccount (bound to `cluster-admin`, with
a long-lived token Secret) in `kube-system` on dev, and writes `server`,
`bearerToken` and `caData` to `kv-prod/argocd/clusters/dev`. Re-running
replaces a stale token and changes nothing when the values match.

Run it BEFORE merging the PR that adds the `clusters-dev` Secret: the
playbook does not depend on the merge, and that removes the error window.
If it runs after the merge, `clusters-dev` shows a `ComparisonError`
between the merge and the first run while Vault holds no fields; that is
expected. Deleting the cluster Secret by hand will not stick, since
`clusters-dev` has selfHeal.

Gate, before running: a sealed Vault looks healthy but the play fails at its
preflight, so run `vault status`
([Is Vault up and unsealed](checks.md#is-vault-up-and-unsealed)). Note prod
`cp1`'s memory in Proxmox; the hub controller starts caching dev once the
cluster is registered, so compare it before and after against the baseline
([Memory, VMs and thin pool](checks.md#memory-vms-and-thin-pool)).

```bash
ansible-playbook -i inventories/shared -i inventories/dev playbooks/dev_register.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_token=<root>
```

A Vault write does not change the git revision, and the repo-server caches
the AVP render by revision, so the hub keeps serving the old render (empty,
or the stale token) until it is refreshed. After the play, log in per
[Log in to the ArgoCD CLI](access.md#log-in-to-the-argocd-cli) and
hard-refresh:

```bash
argocd app get clusters-dev --hard-refresh --grpc-web
argocd cluster list --grpc-web
```

Expect: `failed=0`; `clusters-dev` Synced and Healthy after the hard
refresh; `dev` listed as `Unknown` with "Cluster has no applications and
is not being monitored" (normal: ArgoCD connects to a cluster only once
an Application targets it, so `Successful` and a version appear after the
first dev app syncs, and a bad token is first noticed then). `cp1` memory
should not climb past the baseline; if it climbs toward its ceiling, raise
`cp1` memory in the gitignored `prod.tfvars`, apply, then `qm reboot 3101`
([Resize a node](#resize-a-node)).

If not: `Vault answered 503` is sealed, unseal it by hand; a token Secret
that stays empty means the token controller is not running on dev.

### Deploy ArgoCD to prod

When: first prod bootstrap, or to re-run after the platform PR merges (the
Ingress `letsencrypt-prod` annotation comes from this playbook). It runs on the
operator's workstation against the cluster API and needs Helm and the python
`kubernetes` package locally. The kubeconfig comes from Terraform into a
mode 600 temp file, never kept on disk. `PROD_TMP` here is that temp file,
not the README-convention `$PROD_KC` path. The play does not apply
`argocd/base/projects.yaml` or the app-of-apps; apply those by hand
afterwards.

```bash
PROD_TMP="$(mktemp)"
( cd "$(git rev-parse --show-toplevel)/terraform/environments/prod" && terraform output -raw kubeconfig ) > "$PROD_TMP"
ansible-playbook playbooks/argocd-prod.yaml -e @secret.yaml \
  -e prod_kubeconfig="$PROD_TMP" --ask-vault-pass
kubectl --kubeconfig "$PROD_TMP" -n argocd get pods
rm "$PROD_TMP"
```

Expect: pods `Running` or `Completed`, `repo-server` not in `Init`. If not:
the play fails fast without `prod_kubeconfig`, a missing file, Helm or the
python package; [rebuild.md](../rebuild.md) "Bootstrap the prod hub".

Re-run it after a change to the AVP plugin ConfigMap in
`ansible/roles/argocd/defaults/main.yaml` (the `discover` and `generate`
commands), with the command above. Then check that `repo-server` restarted
(`kubectl --kubeconfig "$PROD_TMP" -n argocd get pods`, look at its age) and
that prod's AVP apps (`monitoring-secrets`, `pve-exporter`,
`cert-manager-issuers`) stay `Synced`; see [ArgoCD](checks.md#argocd).
Watch prod `alerts` and `nfs` too: their paths sit beside a `config.yaml`,
so the plugin's discovery claims them and they move from Argo's own
kustomize to the sidecar with this re-run; they should stay `Synced` with
no diff. Dev's copy of the role may be re-run too, but it is optional; if
it is, dev `nfs` moves the same way, so check it as well.

### Pin names in CoreDNS

When: after every kubeadm upgrade (it can rewrite the ConfigMap), and once
when `vault.mgryn.cc` or `prometheus.mgryn.cc` is first needed in-cluster.

```bash
ansible-playbook playbooks/coredns_hosts.yaml -e @secret.yaml --ask-vault-pass
kubectl --kubeconfig "$DEV_KC" run -it --rm dnscheck --image=busybox:1.36 --restart=Never -- nslookup vault.mgryn.cc
kubectl --kubeconfig "$DEV_KC" run -it --rm dnscheck --image=busybox:1.36 --restart=Never -- nslookup prometheus.mgryn.cc
```

Expect: the first lookup answers `$VAULT_IP`; the second answers the two
prod workers, `$PROD_W1_IP` and `$PROD_W2_IP`. If not: re-run the playbook; check
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
printf 'Vault token: '; read -rs VAULT_TOKEN; echo
ansible-playbook -i inventories/shared playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_seed=true \
  -e vault_token="$VAULT_TOKEN"
unset VAULT_TOKEN
```

Expect: `failed=0`; `vault status` on `vault-02` still unsealed. If not:
unseal, see [access.md](access.md) and [checks.md](checks.md).

### Configure dev

When: first build or after a Vault rebuild, to create the KV mounts and
seed them for dev. Dev has no Vault Kubernetes auth of its own (AVP runs on
the hub and reads `kv-dev` through prod's auth) and no entry in
`vault_k8s_clusters`; `vault_configure_k8s_auth=false` skips Kubernetes
auth altogether, which a run without a prod kubeconfig needs. This also
seeds.

```bash
printf 'Vault token: '; read -rs VAULT_TOKEN; echo
ansible-playbook -i inventories/shared playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=true \
  -e vault_configure_k8s_auth=false -e vault_token="$VAULT_TOKEN"
unset VAULT_TOKEN
```

Expect: `failed=0`; placeholder Applications leave `Unknown` on Argo's next
poll. If not: `vault status` on `vault-02` (sealed), then
[checks.md](checks.md).

### Configure prod

When: after prod's `argocd-config` is `Synced` (it creates the `vault-auth`
ServiceAccount and Secret). Prod has no SSH: its reviewer JWT and CA come from
the kubeconfig on the operator's workstation, so `inventories/shared` alone
suffices. The block fetches a fresh mode 600 kubeconfig from Terraform and
removes it afterwards.

```bash
PROD_TMP="$(mktemp)"
( cd "$(git rev-parse --show-toplevel)/terraform/environments/prod" && terraform output -raw kubeconfig ) > "$PROD_TMP"
printf 'Vault token: '; read -rs VAULT_TOKEN; echo
ansible-playbook -i inventories/shared playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_configure=true \
  -e vault_token="$VAULT_TOKEN" \
  -e '{"vault_k8s_cluster_names":["prod"]}' \
  -e vault_prod_kubeconfig="$PROD_TMP"
unset VAULT_TOKEN
rm "$PROD_TMP"
```

Expect: `vault read auth/kubernetes-prod/config` on `vault-02` shows
`kubernetes_host https://$PROD_CP1_IP:6443`. If not: [checks.md](checks.md).

### Widen prod's policy to read kv-dev

When: `extra_kv_mounts` for prod changed in `roles/vault/defaults/main.yaml`
(the hub's ArgoCD renders dev apps, so `argocd-read-prod` also reads
`kv-dev/`). Re-run [Configure prod](#configure-prod) as written; it rewrites
the policy. Dev's `argocd-read` is untouched. Then check on `vault-02`, with
a short-lived token carrying only the prod policy; the token never prints a
secret value.

```bash
export VAULT_ADDR=https://${VAULT_IP:?}:8200
printf 'Vault token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
vault policy read argocd-read-prod
PROD_ROLE_TOKEN="$(vault token create -policy=argocd-read-prod -ttl=5m -field=token)"
VAULT_TOKEN="$PROD_ROLE_TOKEN" vault kv list kv-dev/monitoring
VAULT_TOKEN="$PROD_ROLE_TOKEN" vault kv list kv-prod/monitoring
unset VAULT_TOKEN PROD_ROLE_TOKEN
```

Expect: the policy names `kv-prod/` and `kv-dev/` data and metadata paths,
and both `kv list` calls print names. The token check proves the policy only, not
the Kubernetes-auth login; the real proof is an Argo sync of a `kv-dev` app on
prod (any `dev-*` app). If not: `permission denied` on
`kv-dev` means the policy was not rewritten; re-run configure prod and
check the play for `Write the policy for prod`.

### Seed the remote-write credential

When: on a rebuild, before prod's `monitoring-secrets` first syncs. That Application renders the Secret
`prometheus-basic-auth` from
`<path:kv-prod/data/monitoring/remote-write#htpasswd>` as soon as the
Secret is on `main`; a missing field fails AVP for the whole app: sync
status `Unknown` with a `ComparisonError`, health still `Healthy`, and the
Grafana and Alertmanager Secrets frozen. `kv-dev/monitoring/remote-write`
holds the plain pair for dev's sender.

Generate the bcrypt line on the operator's workstation with the `argocd`
CLI (`argocd account bcrypt` runs locally and needs no login; it emits
`$2a$`, which ingress-nginx accepts), with the password read without echo:

```bash
printf 'remote-write password: '; read -rs RW_PASS; echo
printf '%s:%s' dev-remote-write "$(argocd account bcrypt --password "$RW_PASS")"; echo
unset RW_PASS
ansible-vault edit secret.yaml
```

In the editor, under `vault_kv`, set `kv-dev` `monitoring/remote-write`
(`username: dev-remote-write`, `password`: the same password) and `kv-prod`
`monitoring/remote-write` (`htpasswd`: the printed line); the shapes are in
`secret.yaml.example`. Then run [Seed](#seed) as written, and check on
`vault-02` without printing the values:

```bash
export VAULT_ADDR=https://${VAULT_IP:?}:8200
printf 'Vault token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
vault kv get -field=htpasswd kv-prod/monitoring/remote-write | cut -c1-20
vault kv get -field=username kv-dev/monitoring/remote-write
unset VAULT_TOKEN
```

Expect: `dev-remote-write:$2y` (the start of the bcrypt line) and
`dev-remote-write`. If not: `No value found` means the seed did not include
the path; check the indentation under `vault_kv` and re-run the seed.

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
kustomize build --enable-helm argocd/apps/<app>/<env>
pre-commit run --all-files
scripts/check-manifests.sh
scripts/check-appsets.sh
bash scripts/tests/check-appsets.test.sh
scripts/check-runbooks.sh
```

Expect: each exits 0. If not: fix what it names; never bypass a hook with
`--no-verify`. Charts are rendered by the kustomization's `helmCharts:`,
so `kustomize build` needs `--enable-helm`; without it a dir with
`helmCharts:` fails.

`scripts/check-appsets.sh` (also run by `check-manifests.sh`) needs bash 4 or
later, for `declare -A`. CI is Linux and unaffected; on macOS the system bash
is 3.2, so run it under a newer one: `brew install bash`, then
`/opt/homebrew/bin/bash scripts/check-appsets.sh`. The ApplicationSet
checks Argo itself must accept are in
[Verify the ApplicationSet](checks.md#verify-the-applicationset).
