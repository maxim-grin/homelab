# Rebuilding from bare metal

The repository alone is not enough. Terraform and
Ansible recreate the machines and their configuration, but the Proxmox host
underneath them — repositories, users, the API token, resource pools and
the VM template every machine clones — is set up by `scripts/pve-bootstrap.sh`,
not Terraform, and the template blocks every `terraform apply` until it
exists.

**What has been exercised, and what has not.** On 2026-09-27 an
unintended apply (#47) rebuilt all three dev VMs from the blank template;
the cluster was recreated by the playbooks in "Rebuild order" and the
jobboard database restored from its old volume on `nfs-01` — see
"Rebuilding dev only". A full run from a fresh Proxmox install on a new
disk has not been done; the bootstrap script has stub tests but has not yet
been run on a real host, so its first real run is the final test.

## What git does not contain

### 1. Proxmox host preparation

None of this is in Terraform; it all precedes the first apply. Run
`scripts/pve-bootstrap.sh` on the new host, as root. It is standalone, so
fetch just that file, read it, and run it with `--dry-run` first, which
prints every command that would change something and changes nothing:

```bash
wget https://raw.githubusercontent.com/maxim-grin/homelab/main/scripts/pve-bootstrap.sh
less pve-bootstrap.sh
bash pve-bootstrap.sh --dry-run
bash pve-bootstrap.sh
```

Name steps to run only those, for example
`bash pve-bootstrap.sh pools talos-template`. The steps are `repos`,
`users`, `pools`, `glance`, `lxc-template`, `ubuntu-template` and
`talos-template`, run in that order by default. The script warns if the node is not named
`pve` (every tfvars file assumes it).

What to expect from a run:

- It prompts for the admin username (or reads `ADMIN_USER`) and, if that
  Linux user does not exist yet, for its password twice. The password is
  never echoed, stored or logged; it goes straight to `chpasswd`.
- It prints the API token secret **once**, when it creates the token.
  Proxmox cannot show it again, so copy it into `pm_api_token_secret`
  immediately. If the token already exists the script says so and leaves
  it; to rotate it, `pveum user token remove terraform@pve terraform` and
  re-run the `users` step.
- It ends by listing the tfvars values it knows: `pm_api_token_id`,
  `debian_lxc_template` and `clone_template_ubuntu`.
- Every step checks what exists first, so it is safe to re-run: on a
  configured host each step reports what it skipped. The one exception is
  the `TerraformProv` role, whose privileges are set again on every run and
  reported as changed. It never destroys a template.

What the steps do, and why:

**Repositories (`repos`).** The enterprise repos (Proxmox and Ceph) fail
without a subscription, so the script sets `Enabled: false` in every
`.sources` file that points at `enterprise.proxmox.com` and adds the
no-subscription one (Proxmox 9 uses deb822 `.sources` files, suite
`trixie`), then runs `apt update`. A failing `apt update` only prints a
warning; the run continues.

**Admin user (`users`)**, for SSH and the web UI: a Linux user in the
`sudo` group, the matching `<user>@pam` Proxmox user, and the
`Administrator` role on `/`.

**Terraform user, role and token (`users`).** A dedicated user with a narrow
role rather than a root token. `terraform@pve` is created with no password,
since only its token is used, and gets the `TerraformProv` role on `/`. The
token is `terraform@pve!terraform`; that id goes into `pm_api_token_id`.
The script creates it with `--privsep 0`, because a privilege-separated
token carries none of the user's permissions and every call would be
refused.

**Resource pools (`pools`)**, which Terraform expects and does not create:
`VM`, `Ubuntu-K8s`, `LXC` and `Talos-K8s`, each with an ACL that lets the
Terraform user place VMs into it. The role carries no `Pool.*` privileges;
granting it on each pool path is what makes pool assignment work.

The `LXC` pool holds the five LAN service containers in
`environments/shared`, and they are created from the Debian 13 LXC template
the `lxc-template` step downloads (`pveam update`, then the newest
`debian-13-standard` template); without the pool's ACL, their placement
fails. `Talos-K8s` is for prod, see section 2b.

### 2. The cloud-init VM template — a hard blocker

`dev.tfvars` sets `clone_template_ubuntu = "ubuntu-cid-tp"`, and every VM in
`terraform/environments/dev/main.tf` is `full_clone = true` from it. On a
fresh host `terraform apply` fails immediately with a template-not-found
error, so the `ubuntu-template` step of `scripts/pve-bootstrap.sh` builds
it.

The step builds the template for Ubuntu 24.04 (noble) as vmid 5000, named
`ubuntu-cid-tp`: it downloads the cloud image into
`/var/lib/vz/template/cache`, checks it against Ubuntu's `SHA256SUMS`,
installs `qemu-guest-agent` into the image with `virt-customize`, imports
the disk to `local-lvm` and converts the VM to a template. Cloud images go
in the cache directory; `/var/lib/vz/dump` is for backups and
`/var/lib/vz/images` for live VM disks. An existing template is skipped. If
vmid 5000 exists but is not a template, the step stops rather than touch it.

**Both open questions were answered on 2026-09-09.** Recorded here so a
rebuild does not re-derive them.

**Cloud-init bus — benign, no change needed.** The template attaches its
drive at `ide2`, while `terraform/modules/ubuntu-vm/main.tf:64` declares
`ide3`. On a Terraform-created VM the result is a single drive on the bus
the module declares:

```
$ qm config 100 | grep -E '^(ide|scsi|agent|boot)'
agent: 1
boot: order=scsi0
ide3: local-lvm:vm-100-cloudinit,media=cdrom
scsi0: local-lvm:vm-100-disk-0,cache=none,discard=on,iothread=1,size=20G,ssd=1
scsihw: virtio-scsi-single
```

No `ide2` survives the clone. The two settings never conflict in practice,
so the template can keep using `ide2`.

**QEMU guest agent — was absent; fixed in the template on 2026-09-09.**
Rebuilding `ubuntu-cid-tp` from a `virt-customize`d image worked: a VM
cloned from it afterwards answers `qm agent <vmid> ping`. New clones
inherit the agent. **The VMs created before that rebuild still do not have
it** — see the ad-hoc Ansible command below. The original diagnosis follows,
because it explains what to look for if this recurs.

**QEMU guest agent — absent, and worth fixing.** The config above sets
`agent: 1`, but the guest never runs one:

```
$ qm agent 100 ping
QEMU guest agent is not running
```

Ubuntu cloud images do not ship `qemu-guest-agent`, and neither the
template build nor any Ansible role installs it. Proxmox is therefore told
to expect an agent that never answers. What that costs:

- `qm shutdown` falls back to ACPI instead of asking the guest to shut down
  cleanly, so a busy VM can be cut off mid-write.
- Proxmox cannot report guest IPs or filesystem usage — the VM's Summary
  page shows no addresses.
- Backups cannot `fs-freeze`, so snapshots are crash-consistent rather than
  clean.
- `ubuntu-vm` sets `agent_timeout = 300`. Applies have not visibly stalled,
  but the provider has a five-minute budget to wait on something that will
  never reply.

The script installs the agent in the image, so a template built from it
inherits the agent.

**Rebuilding an existing template.** Editing the image changes nothing on
an existing host: `qm importdisk` copied the disk when the template was
built, so the template holds its own copy and a later edit to the `.img`
never reaches it. The script skips a template that exists, so to rebuild
it, destroy it and re-run the step:

```bash
qm destroy 5000     # safe: every VM clones with full_clone = true and
                    # holds an independent copy, and ubuntu_vm_1 sets
                    # clone_template = null so it never clones at all
bash pve-bootstrap.sh ubuntu-template
```

The script has no in-place option; customising the template's disk where it
sits is possible by hand but not worth the care it needs.

For the VMs that already exist, install the agent in place — they are all
reachable over SSH:

```bash
ansible all -i inventories/dev/hosts.yaml -e @secret.yaml --ask-vault-pass \
  -b -m apt -a "name=qemu-guest-agent state=present update_cache=true"
```

The alternative is setting `qemu_agent = 0` on the modules and accepting no
guest-reported IP. That is worse: the modules already take their addresses
from the static `ipconfig0`, so the agent costs nothing and buys clean
shutdowns and working backups.

`scsihw` differs too — `virtio-scsi-pci` here versus `virtio-scsi-single` in
the module — but that one is harmless: the module sets it explicitly on
every clone, so the template's value is overridden.

The two-step `qm importdisk` + `qm set --scsi0` form is what the script
uses, because it is known to work. Newer Proxmox can replace the pair with
a single `qm set <vmid> --scsi0 local-lvm:0,import-from=<path>`.

### 2b. The Talos pool and template

Only the prod cluster needs these. Neither is created by Terraform. The
`pools` step creates `Talos-K8s` and grants `terraform@pve` `TerraformProv`
on it; the role carries no `Pool.*` privileges, so without the per-pool ACL
placement fails.

**Template.** The `talos-template` step builds `talos-tp` as vmid 5001: the
Image Factory `nocloud` disk image with the `qemu-guest-agent` extension,
downloaded into `/var/lib/vz/template/iso`, decompressed, imported into a
VM on `local-lvm` and converted to a template. Talos has no SSH and no
package manager, so the guest agent comes from the image, not from a
playbook. Image Factory publishes no checksum for the image (the schematic
id is content-addressed), so the script says so and verifies nothing. As
with the Ubuntu template, an existing template is skipped, and a vmid 5001
that is not a template stops the step.

The version and schematic are constants at the top of the script,
`TALOS_VERSION` and `TALOS_SCHEMATIC` (today `v1.14.2` and
`ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`; the
schematic is the one for `siderolabs/qemu-guest-agent`). They must match
`talos_version` and `talos_schematic_id` in
`terraform/environments/prod/variables.tf`; `scripts/check-talos-pins.sh`
compares them and CI fails if they differ.

**Changing the Talos version.** The template holds a copy of the image, so
a new version means a new template. Destroy the old one, change
`TALOS_VERSION` (and `TALOS_SCHEMATIC`, if the extension list changed) in
the script and the defaults in `variables.tf` together, then re-run the
step:

```bash
qm destroy 5001
bash pve-bootstrap.sh talos-template
```

`terraform@pve` can already clone it because the `TerraformProv` role is
granted on `/` (section 1), so no per-template ACL is needed. Confirm with
`qm config 5001`: `agent: enabled=1`, `scsi0` on `local-lvm`, `ide2` a
cloudinit drive, and no `ipconfig0` on the template itself.

### 3. Proxmox host assumptions Terraform makes

Beyond the users, pools and template above, Terraform assumes these exist
and creates none of them:

| Assumption     | Value       | Used by                                        |
| -------------- | ----------- | ---------------------------------------------- |
| Node name      | `pve`       | `pm_target_node` in `dev.tfvars`               |
| Storage        | `local-lvm` | every `disk_storage`, and the cloud-init drive |
| Network bridge | `vmbr0`     | every `network_bridge`                         |

A pool or storage that does not exist is a hard failure, not a warning. The
API token cannot be exported, so a rebuilt host always needs a fresh one
written into `dev.tfvars`.

### 4. Files that live only on the workstation

None of these are in git, by design. They survive an SSD replacement because
they are on the operator's workstation, not the server — but they do not
survive losing the workstation, and they are what the rebuild needs.

| File                                         | Contains                                                             | If lost                                                                                                                  |
| -------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `terraform/environments/dev/dev.tfvars`        | Proxmox API token, cloud-init password, SSH key paths, every VM's IP | Recreate from the committed `dev.tfvars.example`, then fill in the secrets                                               |
| `terraform/environments/shared/shared.tfvars`  | Proxmox API token, cloud-init password, `nfs-01`'s IP                | Recreate from `shared.tfvars.example`; every value is also in `dev.tfvars`                                               |
| `~/.ssh/homelab_dev`                         | The key every VM trusts                                              | No SSH to any VM. Cloud-init injects the _public_ half at create time, so a new key means recreating every VM            |
| `terraform/environments/dev/terraform.tfstate` | Local backend, 67 KB                                                 | See below                                                                                                                |
| `terraform/environments/shared/terraform.tfstate` | Local backend for `nfs-01`                                        | See below                                                                                                                |
| `terraform/environments/prod/prod.tfvars`      | Proxmox API token and the Talos node map                             | Recreate from the committed `prod.tfvars.example`, then fill in the token                                                |
| `terraform/environments/prod/terraform.tfstate` | Local backend; holds the Talos cluster's PKI and the kubeconfig     | The cluster cannot be managed or reached any more: rebuild it                                                            |
| The ansible-vault password                   | Unlocks `ansible/secret.yaml`                                        | `secret.yaml` is unrecoverable. It holds `host_ips`, `proxmox_vm_ids`, `nfs_server_ip`, `user_name`, `vault_kv` and the SSH key path |
| The Vault unseal key                         | Unseals `vault-02` after every reboot                                | No unseal, ever. Vault stays sealed, AVP renders nothing, every app reading a `<path:...>` degrades                     |
| The Vault root token                         | Auth for `vault kv`, seeding, and configuring auth methods           | Nothing already stored in Vault is lost, but re-seeding or reconfiguring k8s auth needs a new root token from a fresh `vault operator init` |
| `~/.homelab-ca/`                             | The CA that signs Vault's TLS certificate                            | Regenerable: delete, re-run the vault role, refresh the `vault-ca` ConfigMap. No data is lost.                                              |

`secret.yaml` itself **is** committed, encrypted — that part is safe. The
password is not, and should not be. Keep it in a password manager.

### 5. Terraform state after a disk replacement

Each state file lists VMs that no longer exist. Terraform will try to
reconcile against a machine that is gone and produce confusing errors.

After the SSD is replaced, discard it rather than fighting it:

```bash
for env in shared dev prod; do
  cd terraform/environments/$env
  rm terraform.tfstate terraform.tfstate.backup
  terraform init
  terraform apply -var-file=$env.tfvars    # creates everything fresh
  cd -
done
```

`prod` needs the pool and the `talos-tp` template from section 2b first, and
its `prod.tfvars` and `backend.tf` from the workstation.

This is safe _because_ nothing in Proxmox survives the disk swap. Never do it
against a live environment.

## What is destroyed and not backed up

Everything below except Vault lives on the 20 GB NFS export, which lives on
the SSD; Vault's data lives on `vault-02`'s own data disk, also on the SSD.
None of it is backed up.

**As of 2026-09-08 every one of these is empty**, so replacing the disk
costs nothing but the time to rebuild. This section is a standing warning
for later, not a current blocker.

| Data                   | Where                      | State on 2026-09-08 | Reproducible once populated?              |
| ---------------------- | -------------------------- | ------------------- | ----------------------------------------- |
| Grafana dashboards     | `grafana-storage`, 10Gi    | none built          | No — hand-built dashboards are lost       |
| Prometheus metrics     | `prometheus-storage`, 20Gi | empty               | No, and not worth keeping                 |
| Kubernetes PKI, etcd   | control-plane VM           | n/a                 | Regenerated by `kubeadm`                  |
| Vault data             | Raft at `/var/lib/vault/raft`, `vault-02`'s data disk | seeded once above | **Yes**, from a snapshot. Daily raft snapshots land in `/srv/nfs/backups` on `nfs-01`, 14 kept — same SSD, so they cover a bad upgrade or a deleted secret, not a lost disk. Restore per "Restoring Vault from a snapshot" below |

A backup CronJob writing to the NFS export does **not** help: the export is
on the same disk. Any backup worth having has to leave the machine.

## Disk capacity, measured 2026-09-09

`local-lvm` is an LVM thin pool, so `qm` prints an overcommit warning on
every volume it creates. The numbers behind it, from
`lvs -o lv_name,lv_size,data_percent,metadata_percent pve`:

| | |
| --- | --- |
| Pool `pve/data` | 141.23 GiB, **21.4% used** (~30 GiB), metadata 1.8% |
| Declared volume sizes | 143.5 GiB — overcommitted by 2.3 GiB, i.e. 1.6% |
| Free in the volume group | 16 GiB |

The warning is technically accurate and practically irrelevant at this
ratio: if every volume filled to its declared size at once the pool would
be 2.3 GiB short, not tens of gigabytes. Enabling the protection it
suggests is still cheap — set
`activation/thin_pool_autoextend_threshold = 80` and
`thin_pool_autoextend_percent = 20` in `/etc/lvm/lvm.conf` — but it can
only grow into the VG's 16 GiB, so it buys one small extension rather
than safety.

Three later changes moved those numbers, all deliberate overcommit:
`nfs-01` gained two 50 GiB data disks on 2026-09-23 (one per share, see
`terraform/environments/shared`), the three k8s nodes went from the
module's 10 GiB default to 30 GiB the same day — on 10 GiB disks
`/var/lib/containerd` alone reached 3.8 GiB and kubelet evicted pods —
and `nfs-01` gained a third, 10 GiB `scsi3` disk for a `backups` share
exported to `vault-02` for Vault's raft snapshots — a daily timer keeping
14 is coming with the Vault role rebuild, nothing writes to it yet.
Measured after the first two, `pvesm status` reported `local-lvm` 30.2%
used with 98 GiB available. The pool itself is still 141 GiB; declared
sizes now far exceed it and keep drifting further above it with each
addition, so watch actual use rather than the declared total, and act at
about 80%.

**Disk sizes only go up.** `disk_size` in a module can be raised; it cannot
be lowered. Proxmox has no shrink operation — `qm resize` grows only — and
the provider's attempt to detach and re-add the disk fails outright:

```
scsi0:hotplug problem - can't unplug bootdisk 'scsi0'
```

Worse, that failed apply still wrote the smaller value into
`terraform.tfstate`, so Terraform believed `claude-code` had a 20 GiB disk
while Proxmox kept the 60 GiB one, and a subsequent `plan` showed no
difference. If it happens, restore the real value in the module and run
`terraform apply -refresh-only -var-file=dev.tfvars`, which resyncs state
from the API without touching infrastructure.

Growing works, but needs a second step inside the guest — the virtual disk
gets bigger and the filesystem does not follow on its own:

```bash
# after raising disk_size and applying
growpart /dev/sda 1
resize2fs /dev/sda1
```

Genuinely reducing a VM's disk means recreating it:
`terraform apply -replace='module.<name>.proxmox_vm_qemu.ubuntu_vm'`, then
re-running that host's playbook. Weigh that against what the space is worth:
the pool is 21% used, so a 60 GiB allocation using 4.9 costs nothing but an
inflated warning.

**The pressure is per-VM, not pool-wide.** The Kubernetes nodes have 10
GiB roots and are the tightest: worker-02 at 66.9%, worker-01 at 63.3%,
master-01 at 45.9%. Container image churn is what fills them, and a full
node root does not fail politely — kubelet begins evicting pods and
garbage-collecting images. Watch those three long before worrying about
the pool.

Two allocations are simply wasteful and inflate the warning for nothing:
`claude-code` was given 60 GiB and uses 4.9, and `ubuntu` (vmid 100) holds
20 GiB at 0.0% because it has never booted.

## Rebuild order

Each step depends on the one above it. Every `ansible-playbook` command
runs from `ansible/`, and every one needs `-e @secret.yaml
--ask-vault-pass`: host addresses, the SSH user and the key path all come
from `secret.yaml`.

1. **Install Proxmox VE** on the new SSD. Node name must be `pve` or
   `dev.tfvars` needs updating.
2. **Prepare the host** — section 1: run `scripts/pve-bootstrap.sh`. It
   swaps the enterprise repo for no-subscription, adds the admin user,
   creates `terraform@pve` with the `TerraformProv` role and an API token,
   creates the `VM`, `Ubuntu-K8s`, `LXC` and `Talos-K8s` pools with their
   ACLs, creates the read-only `glance@pve` API token for Glance (the
   `glance` step), and downloads the Debian 13 LXC template. Put the
   Terraform token in `dev.tfvars`, the template name the script prints in
   `shared.tfvars` as `debian_lxc_template`, and Glance's token id and
   secret in `secret.yaml` (step 15).
3. **Build the cloud-init template** — section 2. The same script builds it
   (the `ubuntu-template` step, part of a full run) under the name
   `clone_template_ubuntu` expects.
4. **`terraform apply`, `shared` first, then `dev`** —
   `terraform/environments/shared` with `-var-file=shared.tfvars` creates
   `nfs-01` (vmid 103) with its OS disk and the `nfs-dev`, `nfs-prod` and
   `nfs-backups` data disks, `vault-02` (vmid 105) with its data disk, and
   the five LAN service containers (vmids 140–144);
   `terraform/environments/dev` with `-var-file=dev.tfvars` creates the
   other four VMs.
5. **Storage** — the first formats and mounts all three data disks on
   `nfs-01` and exports `nfs-dev` to the dev nodes; the second (default
   dev inventory) prepares the clients. Storage first, because everything
   else claims PVCs from it. `nfs-prod` is exported only to the prod
   workers, so `host_ips` in `secret.yaml` needs `talos-w1`
   (`10.0.0.111`) and `talos-w2` (`10.0.0.112`) before this play runs.
   Prod nodes do not exist yet on a first pass: re-run the play with
   `-i inventories/shared` once they do. Check with `showmount -e` on
   `nfs-01`: the prod path lists exactly those two addresses, the dev
   path is unchanged.

   ```bash
   ansible-playbook -i inventories/shared playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
   ansible-playbook playbooks/nfs_setup.yaml -e @secret.yaml --ask-vault-pass
   ```

6. **kubeadm cluster** — OS preparation, control plane and worker join, in
   one run:

   ```bash
   ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass
   ```

   The workers join with a command the control-plane play creates with
   `set_fact`, which exists only for the length of one `ansible-playbook`
   run. `join_workers.yaml` on its own therefore always fails; to re-run
   the join, pass both playbooks to one invocation:
   `ansible-playbook playbooks/cluster_init.yaml playbooks/join_workers.yaml
   -e @secret.yaml --ask-vault-pass`.
7. **Build `vault-02`** — install the collections it needs, then install
   Vault on the VM:

   ```bash
   ansible-galaxy collection install -r requirements.yml
   ansible-playbook -i inventories/shared playbooks/vault.yaml -e @secret.yaml --ask-vault-pass
   ```

   Then, by hand on `vault-02` (Ansible never sees the unseal key or root
   token, and should not):

   ```bash
   # the role put the CA in the host's trust store, so HTTPS just works
   export VAULT_ADDR=https://10.0.0.133:8200
   vault operator init -key-shares=1 -key-threshold=1
   ```

   Record the unseal key and the root token in the password manager now —
   there is no recovery from losing the unseal key, ever. Then, still on
   `vault-02`:

   ```bash
   export VAULT_ADDR=https://10.0.0.133:8200
   vault operator unseal
   ```

   Configuring and seeding `vault-02` needs the `vault-auth-token` Secret
   that `argocd-config` creates — see the "Configure and seed `vault-02`"
   step below, after `argocd-config` has synced.
8. **ArgoCD via Helm:**

   ```bash
   ansible-playbook playbooks/argocd-dev.yaml -e @secret.yaml --ask-vault-pass
   ```

   The UI login is `admin`, with the password whose bcrypt hash is
   `argocd_admin_password_hash` in `secret.yaml`. The play asserts that hash
   is present before installing, so a forgotten value fails here rather than
   leaving a random password in `argocd-initial-admin-secret`. Before Helm
   runs, `ansible/roles/argocd` also creates the `cmp-plugin` ConfigMap and
   `argocd-vault-plugin-config` Secret that the argocd-vault-plugin (AVP)
   sidecar in `argocd-repo-server` needs — that ordering is what keeps
   `argocd-repo-server` out of `Init`. The Helm task does not wait, so on
   an upgrade where the new repo-server wedges, the old pod keeps serving
   and the playbook still reports `changed`; confirm
   `kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server`
   shows `2/2` before continuing.
9. **Out-of-band Secrets** — creates the `grafana-admin` Secret from
   `secret.yaml`:

   ```bash
   ansible-playbook playbooks/cluster_secrets.yaml -e @secret.yaml --ask-vault-pass
   ```

   **Run this before step 11**, which starts ArgoCD syncing the monitoring
   app: Grafana seeds its admin password only when it first creates its
   database, so an install without the Secret keeps the default until it
   is destroyed and rebuilt.
   - **Grafana** reads `GF_SECURITY_ADMIN_PASSWORD` through a `secretKeyRef`
     with no `optional: true`, so until this runs the pod sits in
     `CreateContainerConfigError` — loud, deliberately, rather than
     silently starting on the default password. On an instance whose PVC
     already holds a Grafana database, reset it explicitly:
     `kubectl -n monitoring exec deploy/grafana -- grafana-cli admin reset-admin-password <pw>`.
10. **`kubectl apply -f argocd/base/projects.yaml`** — the AppProject. Nothing
    has applied it yet at this point in a rebuild, so it must go on by hand;
    from here on, the `argocd-config` Application syncs it. This same command
    is also the only recovery if the AppProject is ever deleted from a running
    cluster: `argocd-config` declares `project: homelab`, so once that project
    is gone ArgoCD can no longer sync `argocd-config` either, and nothing is
    left that can recreate the AppProject except this manual apply.
11. **`kubectl apply -f argocd/environments/dev/applications/app-of-apps.yaml`**
    — `root-dev` then pulls in ingress-nginx, nfs, cert-manager and its
    issuers, monitoring, jobboard, and `argocd-config` itself. `argocd-config` syncing
    `argocd/base/` is what creates the `vault-auth` ServiceAccount,
    ClusterRoleBinding and `vault-auth-token` Secret in
    `argocd/base/vault-auth-delegator.yaml` — needed by the next step.

    ArgoCD syncs the jobboard manifests as soon as this applies, and
    `argocd/apps/jobboard/dev/kustomization.yaml` names a specific published
    version. That version must already exist in GHCR: the app repo publishes
    only from a `v<version>` git tag. If it does not, the pod sits in
    `ImagePullBackOff` until someone cuts the tag, and recovers on its own
    once the image appears — the manifests are correct either way. This is
    the one ordering hazard that used to be silent: with `:latest` the pod
    would happily start the *previous* build instead.

    Separately, expect jobboard's sync status to sit at `Unknown` with a
    `ComparisonError` naming a permission denied or a sealed Vault for
    however long it takes to reach step 12 below — Vault's Kubernetes auth
    is not configured until then. That is expected, not a wiring fault; it
    clears once step 12 runs.
12. **Configure and seed `vault-02`** — now that `argocd-config` has synced
    and created the `vault-auth-token` Secret, finish step 7 above:

    ```bash
    ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml \
      -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=true \
      -e vault_token=<root token> -e '{"vault_k8s_cluster_names":["dev"]}'
    ansible-playbook playbooks/coredns_hosts.yaml -e @secret.yaml --ask-vault-pass
    ```

    then add a DNS-only Cloudflare record, `vault.mgryn.cc` → `10.0.0.133`.
    `vault-02` is the Vault that AVP reads, so this configures the Vault
    that jobboard and ArgoCD read from today. `vault_configure=true` also
    wires Vault's Kubernetes auth method (`disable_local_ca_jwt: true`),
    the `argocd-read` policy, and the `argocd` role bound to
    `system:serviceaccount:argocd:argocd-repo-server` — the path AVP
    actually uses to authenticate, never the root token —
    `vault_configure_k8s_auth` defaults to true. The task that posts the
    config is `no_log: true` (the body carries the root token, the
    reviewer JWT and the cluster CA together); see `ansible/README.md`
    for how to diagnose a failure here.
13. **The workstation VM:**

    ```bash
    ansible-playbook playbooks/workstation.yaml -e @secret.yaml --ask-vault-pass
    ```

14. **Point `/etc/hosts`** at a node IP for `dev-argocd.mgryn.cc`,
    `grafana.mgryn.cc` and
    `prometheus.mgryn.cc`. One line per name, all pointing at the same node
    -- ingress-nginx is a DaemonSet on host ports 80/443, so any node
    answers.

    `jobs.mgryn.cc` needs no entry: it is a DNS-only Cloudflare record
    holding a node IP. If the node IPs changed in this rebuild, update that
    record in Cloudflare instead. Its certificate re-issues on its own,
    provided the Vault seed in step 12 included `cert-manager/cloudflare`.
    Grafana renders absolute URLs from `GF_SERVER_ROOT_URL`, so a name
    that does not resolve produces broken login redirects rather than a
    connection error.

    `vault.mgryn.cc`, like `jobs.mgryn.cc`, needs no `/etc/hosts` entry
    either: it is a DNS-only Cloudflare record pointing at `vault-02`
    (`10.0.0.133`), not a node. Vault is not behind ingress-nginx, so
    it stays reachable at `https://vault.mgryn.cc:8200` (verify with
    `--cacert ~/.homelab-ca/ca.crt`) even when the cluster itself is down
    — which is exactly when an operator needs to check whether it is
    sealed.

15. **LAN services** — from `ansible/`:

    ```bash
    ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass
    ```

    Each service's play is added as its role lands; see the
    [LAN services design](superpowers/specs/2026-09-27-lan-services-design.md).

    **Pi-hole** needs `pihole_admin_password` in `secret.yaml`. Check it
    from the workstation before pointing anything at it:
    `dig @10.0.0.140 example.com +short` answers, and
    `dig @10.0.0.140 doubleclick.net +short` returns `0.0.0.0`. If it
    instead returns a real address, the installer's own `pihole-FTL`
    started before gravity finished building and is stuck holding a
    stale database handle — `systemctl restart pihole-FTL` on the
    container fixes it; the role now restarts FTL and self-heals this on
    its own re-runs, so seeing it at all here means the very first run
    was interrupted before it could.

    The role returns before FTL is serving again (the restart is a
    handler), so a scripted check right after a run, such as the `dig`
    above, should retry for about 10 seconds before it calls a failure.

    A half-finished install (interrupted before `/usr/local/bin/pihole`
    exists) is safe to resume: re-running the play retries the
    installer from scratch. If it instead insists Pi-hole is already
    installed but nothing works, `pihole -r` (reconfigure) or removing
    `/usr/local/bin/pihole` and re-running the play forces a clean one.

    **Traefik** needs `traefik_cloudflare_api_token` (its own token:
    Zone → DNS → Edit and Zone → Zone → Read on `mgryn.cc`) and
    `traefik_dashboard_users` in `secret.yaml`, and a DNS-only Cloudflare
    record `*.hl.mgryn.cc` → `10.0.0.141`. Issue from staging first
    (`-e traefik_cert_resolver=letsencrypt-staging`), then re-run without
    it — switching resolvers is just re-running with or without that
    flag; the role removes the *other* resolver's ACME storage file each
    run, so it is a clean re-issue rather than a resurrected stale
    certificate. Production allows five failed validations per hostname
    per hour. If Traefik's journal shows `Invalid format for Authorization
    header`, the token in `secret.yaml` is malformed (stray quotes or
    whitespace). Wait for issuance before checking — `journalctl -u
    traefik -f` until a certificate is obtained, ~1-2 minutes; curling
    immediately after the run only shows TRAEFIK DEFAULT CERT. Once
    issued, `curl -v https://pihole.hl.mgryn.cc/admin/` from the
    workstation shows a Let's Encrypt certificate for `*.hl.mgryn.cc`.

    **Gatus** needs `gatus_telegram_token`, `gatus_telegram_chat_id`,
    `gatus_basic_user`, `gatus_basic_password` and
    `gatus_basic_password_bcrypt` in `secret.yaml` (the comments in
    `secret.yaml.example` say where each comes from, including the
    `htpasswd -nbB <user> '<password>' | cut -d: -f2` command for the
    hash) and `~/.homelab-ca/ca.crt` on the workstation, which
    `playbooks/vault.yaml` created. Re-run the Traefik play too, for the
    `status.hl.mgryn.cc` route. Check: `https://status.hl.mgryn.cc` asks
    for the Gatus login, and after it shows every endpoint green, and
    `pct stop 140` on the host sends a Telegram alert within about two
    minutes (two check intervals), `pct start 140` a recovery. An outage
    sends one message per failing endpoint, not one per host: stopping
    Pi-hole sends two (Pi-hole DNS and `pihole.hl.mgryn.cc`), a Traefik
    outage one per `*.hl` name — each followed by its own recovery.

    **LAN Orangutan** needs `orangutan_password` in `secret.yaml`.
    Re-run the Traefik and Gatus plays too, for `lan.hl.mgryn.cc` and its
    check. Check: `https://lan.hl.mgryn.cc` asks for that password and,
    within five minutes, lists the LAN's devices with MAC addresses and
    vendors. The package also leaves its own unused
    `/etc/lan-orangutan/config.ini`; the service reads
    `/etc/orangutan/config.ini`, so run the CLI as `runuser -u orangutan --
    env ORANGUTAN_DATA_DIR=/var/lib/orangutan orangutan list --config
    /etc/orangutan/config.ini`.

    **Glance** needs, before its play:

    - a read-only Proxmox token: the `glance` step of `pve-bootstrap.sh`
      creates `glance@pve` with the built-in `PVEAuditor` role and the
      token `glance`; the id `glance@pve!glance` and the secret it prints
      once go into `secret.yaml` as `glance_proxmox_token_id` and
      `glance_proxmox_token_secret`. If the token already exists its
      secret cannot be shown again: `pveum user token remove glance@pve
      glance`, then re-run `bash pve-bootstrap.sh glance`;
    - Pi-hole's application password, kept from before the rebuild — both
      `pihole_app_password` and `pihole_app_pwhash` are in `secret.yaml`,
      and the Pi-hole play applies the hash. Only if they were lost:
      log in to Pi-hole's API with the admin password, `GET /api/auth/app`,
      keep `.app.password` and `.app.hash`, and re-run the Pi-hole play.

    Re-run the Pi-hole, Traefik and Gatus plays too. Check:
    `https://home.hl.mgryn.cc` shows every VM and container, Pi-hole's
    statistics and Gatus's endpoints. If the Services widget shows ERROR
    for every hostname while the IP-based widgets work, the container is
    resolving through the router first: `pct exec 142 -- cat
    /etc/resolv.conf` should list `1.1.1.1` first, and `pct exec 142 --
    getent hosts vault.mgryn.cc` should answer. See "Stale resolv.conf
    after a nameserver change" in `docs/operations.md`.

    **Pi-hole for clients** — last, once Gatus is watching Pi-hole: the
    router cannot hand out a DNS server, so set `10.0.0.140` as the only
    DNS server in the network settings of each device that should use it
    (see "Pointing a device at Pi-hole" in `docs/operations.md`).

16. **The Talos prod cluster** — section 2b first. Then, from the operator's
    workstation, in `terraform/environments/prod`:

    ```bash
    cp prod.tfvars.example prod.tfvars   # fill in the token and the node map
    cp backend.tf.example backend.tf
    terraform init
    terraform apply -var-file=prod.tfvars
    terraform output -raw kubeconfig > ~/.kube/talos-prod
    KUBECONFIG=~/.kube/talos-prod kubectl get nodes
    ```

    Done when `kubectl get nodes` shows three Ready nodes: `talos-prod-cp1`,
    `talos-prod-w1` and `talos-prod-w2`. The cluster has no workloads; the
    hub platform is sub-project 3 of the roadmap.

    Right after the apply returns, `kubectl get nodes` prints `No resources
    found`: the API server answers but the kubelets have not registered.
    Retry for a few minutes. If a node is still missing after about ten,
    `talosctl -n <ip> health` and `talosctl -n <ip> services` (with
    `talosconfig` fetched as below) or `qm terminal <vmid>` on `pve` show
    what it is waiting for.

    If the apply fails on the config step with `UnattendedInstallConfig
    config is incompatible with v1alpha1 config (.machine.install)`, a
    patch in `talos.tf` sets the deprecated `machine.install`. Talos 1.14
    takes the installer image and disk from the `UnattendedInstallConfig`
    document, so patch that instead (ADR
    [0021](decisions/0021-talos-prod-via-terraform-provider.md)). The
    VMs already exist, so fix the patch and apply again with the same
    state.

    The cluster's PKI exists only in `terraform.tfstate`, so a lost state
    means rebuilding the cluster, as for every other environment after an SSD
    replacement. Fetch `talosconfig` the same way as `kubeconfig` if you need
    `talosctl`: `terraform output -raw talosconfig > ~/.talos/config`.

    **Resizing a node.** Edit `memory` in `talos_nodes` and apply. The VM
    keeps running with the old size until restarted, because the module sets
    `automatic_reboot = false`. One node at a time: `kubectl drain`, then
    `qm reboot <vmid>` on `pve` (a guest-level `talosctl reboot` does not pick
    up the new size), then `kubectl uncordon`.

17. **Bootstrap the prod hub** — ArgoCD on the Talos cluster, with Vault's
    prod auth ([ADR 0024](decisions/0024-hub-in-prod.md)). Every command
    runs on the operator's workstation, which needs `helm`, `kubectl` and
    the python `kubernetes` package for the Ansible controller's Python.
    Ansible has no SSH target on Talos; it talks to the cluster API
    through a kubeconfig.

    Prerequisites:

    - Prod nodes at 4G memory and `nfs-prod` exported to the prod
      workers (the hub-nodes PR applied).
    - PR 1 (hub-nodes) and PR 2 (hub-bootstrap) merged to `main` before
      step 4; steps 1-3 can run from the branch. `root-prod` reads
      `main`, so applying it earlier deploys stale apps and never
      creates the `vault-auth` Secret.
    - `kv-prod` seeded. Step 17.7 below resolves a `kv-prod` placeholder, and
      nothing else seeds it. With the `kv-prod` block of `secret.yaml`
      filled in (see `secret.yaml.example`), seed from `ansible/`;
      `vault_configure` stays false:

      ```bash
      ansible-playbook -i inventories/shared playbooks/vault.yaml \
        -e @secret.yaml --ask-vault-pass -e vault_seed=true \
        -e vault_token=<root token>
      ```

      The play also re-runs the install, TLS and service tasks, which are
      idempotent; a service restart would seal Vault, so check
      `vault status` afterwards. Check the seed on `vault-02` without
      printing the password:
      `vault kv get -field=admin-user kv-prod/monitoring/grafana` prints
      `admin`.

    1. Extract the kubeconfig into a mode-600 temp file. It is a sensitive
       Terraform output and is never kept on disk beyond this run:

       ```bash
       cd terraform/environments/prod
       umask 077; PROD_KC="$(mktemp)"
       terraform output -raw kubeconfig > "$PROD_KC"
       cd ../../../ansible
       ```

    2. Optional, first: re-run `playbooks/argocd-dev.yaml -e @secret.yaml
       --ask-vault-pass` so dev's ArgoCD answers as `dev-argocd.mgryn.cc`
       (the rename that frees `argocd.mgryn.cc` for the hub), and add
       `dev-argocd.mgryn.cc` to `/etc/hosts` pointing at a dev node IP.

    3. Deploy ArgoCD. `prod_kubeconfig` is required; the play fails fast
       without it:

       ```bash
       ansible-playbook playbooks/argocd-prod.yaml -e @secret.yaml \
         -e prod_kubeconfig="$PROD_KC" --ask-vault-pass
       kubectl --kubeconfig "$PROD_KC" -n argocd get pods
       ```

       Done when every pod is `Running` or `Completed` and `repo-server`
       is not stuck in `Init`.

    4. PR 1 (hub-nodes) and PR 2 (hub-bootstrap) are merged to `main`
       before this step; steps 1-3 can run from the branch. Apply the
       AppProject and the app-of-apps by hand, as on dev (steps 10 and
       11); the `argocd` role does not apply them:

       ```bash
       kubectl --kubeconfig "$PROD_KC" apply -f ../argocd/base/projects.yaml
       kubectl --kubeconfig "$PROD_KC" apply \
         -f ../argocd/environments/prod/applications/app-of-apps.yaml
       ```

    5. Wait for `argocd-config` to be `Synced`. It creates the
       `vault-auth` ServiceAccount and Secret that Vault's prod auth
       reads. This is the chicken-and-egg: Vault's prod auth needs that
       Secret, and Applications with `<path:...>` placeholders sync only
       after Vault is configured. `argocd/base` has no placeholders, so
       `argocd-config` syncs without AVP.

    6. Configure Vault's prod auth mount. Prod's reviewer JWT and CA come
       from the kubeconfig, not SSH, so `inventories/dev` is not needed
       for a prod-only run; `vault_seed` is not needed either:

       ```bash
       ansible-playbook -i inventories/shared playbooks/vault.yaml \
         -e @secret.yaml --ask-vault-pass -e vault_configure=true \
         -e vault_token=<root token> \
         -e '{"vault_k8s_cluster_names":["prod"]}' \
         -e vault_prod_kubeconfig="$PROD_KC"
       ```

       Done when `vault read auth/kubernetes-prod/config` on `vault-02`
       shows `kubernetes_host https://10.0.0.110:6443`. Placeholder
       Applications read `Unknown` until this runs and clear on Argo's
       next poll.

    7. Prove AVP end to end. ArgoCD renders only from git and no
       committed manifest carries a `kv-prod` placeholder, so run the
       plugin directly in the repo-server's `avp` sidecar, which has the
       `AVP_*` and `VAULT_*` variables (`envFrom` the
       `argocd-vault-plugin-config` Secret) and the binary at
       `/usr/local/bin/argocd-vault-plugin`. It logs in to Vault's
       `kubernetes-prod` mount with the pod's ServiceAccount token. The
       field is `admin-user`, not the password, so nothing sensitive is
       printed. Nothing is committed or applied:

       ```bash
       kubectl --kubeconfig "$PROD_KC" -n argocd exec -i \
         deploy/argocd-repo-server -c avp -- \
         argocd-vault-plugin generate - <<'EOF'
       apiVersion: v1
       kind: ConfigMap
       metadata:
         name: avp-check
         annotations:
           avp.kubernetes.io/path: kv-prod/data/monitoring/grafana
       data:
         user: <admin-user>
       EOF
       ```

       Expect a ConfigMap whose `user` is `admin`. Failure shows as a
       non-zero exit with an error from Vault or the login, the same one
       an Application reports as `ComparisonError`. Check `vault status`
       on `vault-02` first (sealed Vault), then that `kv-prod` is seeded
       and step 6 ran.

    8. Check the UI. Prod has no ingress controller until PR 3, so use the
       NodePort: `http://10.0.0.111:32080` (or `.112`, or HTTPS on
       `32443`) shows the login page. If step 2 was done,
       `dev-argocd.mgryn.cc` still lists dev's Applications `Synced`.

    9. Delete the kubeconfig: `rm "$PROD_KC"`.

Expect steps 10 and 11 to be the confusing ones: ArgoCD reads `main` from
GitHub, not the local checkout, so anything uncommitted is invisible to it.

### Restoring Vault from a snapshot

Snapshot files are `vault-<UTC timestamp>.snap` in `/srv/nfs/backups` on
`nfs-01`. Restoring one needs the unseal key and root token the snapshot
was taken under — not any key or token generated afterward.

On a fresh `vault-02` (after its own `vault operator init` and
`vault operator unseal`, step 7 above):

```bash
vault operator raft snapshot restore -force <file>
```

then unseal with the **original** unseal key and log in with the
**original** root token — the ones recorded when the snapshot's data was
written, not the fresh store's own. The drill that proves this works
end-to-end is PR 4's (Task 14).

## Rebuilding dev only

When the dev VMs are recreated but the host, `nfs-01` and `vault-02` are
not — a `terraform apply` that replaced them, as PR #47's module rename
did on 2026-09-27 — skip steps 1–5 and 7 above, and step 13 unless `claude-code` was
replaced too. Vault is initialised
and seeded, NFS still holds every PVC's data, and the node vmids and IPs
come back unchanged, so `/etc/hosts` and the Cloudflare records need
nothing.

From the workstation, in `ansible/`:

```bash
# New VMs, new SSH host keys. host_key_checking = False keeps Ansible
# going, but every connection warns until the stale keys are removed.
ssh-keygen -R <master-ip>; ssh-keygen -R <worker-01-ip>; ssh-keygen -R <worker-02-ip>

ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass
# New cluster, new CA: the old kubeconfig no longer authenticates.
ssh <master-ip> sudo cat /etc/kubernetes/admin.conf > ~/.kube/homelab-dev.conf
export KUBECONFIG=~/.kube/homelab-dev.conf

ansible-playbook playbooks/argocd-dev.yaml -e @secret.yaml --ask-vault-pass
ansible-playbook playbooks/cluster_secrets.yaml -e @secret.yaml --ask-vault-pass
kubectl apply -f ../argocd/base/projects.yaml
kubectl apply -f ../argocd/environments/dev/applications/app-of-apps.yaml

# once argocd-config has created it:
kubectl -n argocd get secret vault-auth-token

# Point Vault's Kubernetes auth at the new cluster's CA and reviewer JWT.
# The KV store is already seeded, so no seed.
ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml \
  -e @secret.yaml --ask-vault-pass -e vault_configure=true -e vault_seed=false \
  -e vault_token=<root token> -e '{"vault_k8s_cluster_names":["dev"]}'
ansible-playbook playbooks/coredns_hosts.yaml -e @secret.yaml --ask-vault-pass
```

Applications that carry `<path:...>` placeholders show `Unknown` until
the Vault step runs, and clear on Argo's next poll. jobboard restarting
a few times at first is its database host not resolving yet; it settles.

**Verify from the workstation, not a node.** `curl https://jobs.mgryn.cc`
run on a node returns `000`: a node cannot reach its own host port through
its LAN address. From the workstation it returns `303` to the login page.
There is no metrics-server, so `kubectl top` does not work; use `free -m`
on the nodes.

### The new cluster starts with empty volumes

Every PVC is new, so `nfs-dev` gives each one a new directory,
`/srv/nfs/k8s/<namespace>-<pvc>-<pv>`. The old cluster's directories are
still there, untouched — their PVCs were never deleted, so the provisioner
never removed them. jobboard comes up with its schema and no rows. To bring
the old database back, pause ArgoCD first; otherwise selfHeal scales
Postgres back up mid-copy. `root-dev` before `jobboard`, or `root-dev`
restores `jobboard`'s sync policy at once:

```bash
kubectl -n argocd patch application root-dev --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl -n argocd patch application jobboard --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl -n jobboard scale deploy/jobboard --replicas=0
kubectl -n jobboard scale sts/postgres --replicas=0
kubectl -n jobboard wait --for=delete pod/postgres-0 --timeout=2m
```

On `nfs-01`, find the two `jobboard-data-postgres-0-pvc-*` directories
with `ls -la /srv/nfs/k8s/` and tell them apart by date:

```bash
O=/srv/nfs/k8s/jobboard-data-postgres-0-pvc-<old>
N=/srv/nfs/k8s/jobboard-data-postgres-0-pvc-<new>
sudo cat "$O/pgdata/PG_VERSION"          # the major version the image runs
sudo mv "$N/pgdata" "$N/pgdata.empty"
sudo cp -a "$O/pgdata" "$N/pgdata"       # -a keeps UID 999 ownership
```

Then scale `postgres` to 1, wait for Ready, check a row count with `psql`,
scale `jobboard` to 1, and re-apply `app-of-apps.yaml` to restore
auto-sync on both. The password matches because both databases were
initialised from the same Vault secret. Delete the old directory and
`pgdata.empty` once the app is confirmed working.

## Gaps worth closing before the disk is replaced

Roughly in order of how much they would hurt. None is urgent while the
cluster holds no data.

1. **Install `qemu-guest-agent` on the VMs built before 2026-09-09.** The
   template now carries it and new clones inherit it, verified with
   `qm agent 102 ping`. The five older VMs still run without it while
   Proxmox is configured to expect one, so their shutdowns are ACPI-only
   and backups cannot freeze their filesystems.
2. **Script the template build.** The commands above are a start; a
   `scripts/build-template.sh` would be better than a document that can drift.
3. **Store the ansible-vault password, and the Vault unseal key and root
   token, in a password manager** if they are not already there. This is
   the one that bites without warning: `secret.yaml` is committed and
   encrypted, so losing the password loses the file, and Vault has no
   recovery path at all without its unseal key — a sealed Vault with a
   lost key is unseal-able forever, not just inconvenient.
4. **Export Grafana dashboards to git** once any are built.
