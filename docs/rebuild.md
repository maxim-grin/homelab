# Rebuilding from bare metal

The repository alone is not enough. Terraform and
Ansible recreate the machines and their configuration, but the Proxmox host
underneath them — repositories, users, the API token, resource pools and
the VM template every machine clones — is set up by hand, and the template
blocks every `terraform apply` until it exists.

## What git does not contain

### 1. Proxmox host preparation

None of this is in Terraform; it all precedes the first apply.

**Repositories.** The enterprise repo 403s without a subscription, so disable
it and add the no-subscription one. Proxmox 9 uses deb822 `.sources` files:

```bash
# /etc/apt/sources.list.d/pve-enterprise.sources -- set Enabled: false
cat > /etc/apt/sources.list.d/pve-no-subscription.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update
```

**Admin user**, for SSH and the web UI:

```bash
adduser user1 && usermod -aG sudo user1
pveum user add user1@pam -comment "user1 admin"
pveum acl modify / --roles Administrator --users user1@pam
pveum passwd user1@pam
```

**Terraform user, role and token.** A dedicated user with a narrow role
rather than a root token:

```bash
pveum user add terraform@pve --password '<PASSWORD>'
pveum role add TerraformProv -privs \
  "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit \
   VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
   VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt \
   Datastore.AllocateSpace Datastore.Audit"
pveum aclmod / -user terraform@pve -role TerraformProv
```

Then Datacenter > Permissions > API Tokens > Add, user `terraform@pve`.
The token id looks like `terraform@pve!terraform`; that and the secret go
into `pm_api_token_id` and `pm_api_token_secret`.

**Resource pools**, which Terraform expects and does not create, plus the
ACL that lets the Terraform user place VMs into them. The role above
carries no `Pool.*` privileges; granting it on each pool path is what makes
pool assignment work:

```bash
pveum pool add VM
pveum pool add Ubuntu-K8s
pveum pool list

pveum aclmod /pool/VM         -user terraform@pve -role TerraformProv
pveum aclmod /pool/Ubuntu-K8s -user terraform@pve -role TerraformProv
```

`LXC` is referenced only by the commented-out n8n module; create it, and
grant the same ACL, if that block is ever uncommented.

**LXC templates**, needed only if the n8n module or the prod environment is
ever enabled:

```bash
pveam update
pveam available | grep debian-13
pveam download local debian-13-standard_13.0-1_amd64.tar.zst
```

The version string matters: `dev.tfvars` pins
`local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst`, and whatever is
downloaded has to match that string exactly or container creation fails
with a template-not-found error. Update the tfvars to whatever `pveam
available` currently offers rather than hunting for an old build.

### 2. The cloud-init VM template — a hard blocker

`dev.tfvars` sets `clone_template_ubuntu = "ubuntu-cid-tp"`, and every VM in
`proxmox/environments/dev/main.tf` is `full_clone = true` from it. Nothing in
this repository creates it. On a fresh host `terraform apply` fails
immediately with a template-not-found error.

The steps used originally, for Ubuntu 24.04 (noble). Cloud images go in
`/var/lib/vz/template/cache`; `/var/lib/vz/dump` is for backups and
`/var/lib/vz/images` for live VM disks.

```bash
mkdir -p /var/lib/vz/template/cache
cd /var/lib/vz/template/cache
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 5000 --memory 2048 --cores 2 --name ubuntu-cid-tp
qm importdisk 5000 noble-server-cloudimg-amd64.img local-lvm
qm set 5000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-5000-disk-0
qm set 5000 --ide2 local-lvm:cloudinit
qm set 5000 --boot c --bootdisk scsi0
qm set 5000 --serial0 socket --vga serial0
qm template 5000
```

**Both open questions were answered on 2026-09-09.** Recorded here so a
rebuild does not re-derive them.

**Cloud-init bus — benign, no change needed.** The template attaches its
drive at `ide2`, while `proxmox/modules/ubuntu-vm/main.tf:64` declares
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

Fix it in the image, so a template built from it inherits the agent:

```bash
apt-get install -y libguestfs-tools
cd /var/lib/vz/template/cache
virt-customize -a noble-server-cloudimg-amd64.img --install qemu-guest-agent
```

**That alone changes nothing on an existing host.** `qm importdisk` copied
the disk when the template was built, so the template holds its own copy
and a later edit to the `.img` never reaches it. On a fresh rebuild the
ordering in this document is already correct -- customise, then create.
On a host that already has a template, rebuild it:

```bash
qm destroy 5000     # safe: every VM clones with full_clone = true and
                    # holds an independent copy, and ubuntu_vm_1 sets
                    # clone_template = null so it never clones at all
```

then re-run the `qm create` sequence above. The alternative, if destroying
the template is unwelcome, is to customise its disk in place --
`virt-customize -a /dev/pve/vm-5000-disk-0 --install qemu-guest-agent`,
confirming the volume name with `lvs` first.

For the VMs that already exist, install it in place — they are all
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

Newer Proxmox can replace the `importdisk` + `set --scsi0` pair with a
single `qm set <vmid> --scsi0 local-lvm:0,import-from=<path>`; the two-step
form above is what was actually used and is known to work.

The `talos-tp` template hard-coded at `proxmox/environments/prod/main.tf:15`
is likewise absent and undocumented. Nothing applies it, so it can be
ignored unless that changes.

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
they are on the laptop, not the server — but they do not survive losing the
laptop, and they are what the rebuild needs.

| File                                         | Contains                                                             | If lost                                                                                                                  |
| -------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `proxmox/environments/dev/dev.tfvars`        | Proxmox API token, cloud-init password, SSH key paths, every VM's IP | Recreate from the committed `dev.tfvars.example`, then fill in the secrets                                               |
| `~/.ssh/homelab_dev`                         | The key every VM trusts                                              | No SSH to any VM. Cloud-init injects the _public_ half at create time, so a new key means recreating every VM            |
| `proxmox/environments/dev/terraform.tfstate` | Local backend, 67 KB                                                 | See below                                                                                                                |
| The ansible-vault password                   | Unlocks `ansible/secret.yaml`                                        | `secret.yaml` is unrecoverable. It holds `host_ips`, `proxmox_vm_ids`, `nfs_server_ip`, `user_name` and the SSH key path |

`secret.yaml` itself **is** committed, encrypted — that part is safe. The
password is not, and should not be. Keep it in a password manager.

### 5. Terraform state after a disk replacement

The state file lists VMs that no longer exist. Terraform will try to
reconcile against a machine that is gone and produce confusing errors.

After the SSD is replaced, discard it rather than fighting it:

```bash
cd proxmox/environments/dev
rm terraform.tfstate terraform.tfstate.backup
terraform init
terraform apply -var-file=dev.tfvars    # creates everything fresh
```

This is safe _because_ nothing in Proxmox survives the disk swap. Never do it
against a live environment.

## What is destroyed and not backed up

Everything below lives on the 20 GB NFS export, which lives on the SSD, and
none of it is backed up.

**As of 2026-09-08 every one of these is empty**, so replacing the disk
costs nothing but the time to rebuild. This section is a standing warning
for later, not a current blocker.

| Data                   | Where                      | State on 2026-09-08 | Reproducible once populated?              |
| ---------------------- | -------------------------- | ------------------- | ----------------------------------------- |
| Gitea repositories     | `gitea-data`, 10Gi         | empty               | **No.** Anything pushed only here is gone |
| Harbor registry images | `harbor-registry`, 10Gi    | empty               | Only if the images exist elsewhere        |
| Grafana dashboards     | `grafana-storage`, 10Gi    | none built          | No — hand-built dashboards are lost       |
| Prometheus metrics     | `prometheus-storage`, 20Gi | empty               | No, and not worth keeping                 |
| Kubernetes PKI, etcd   | control-plane VM           | n/a                 | Regenerated by `kubeadm`                  |

Gitea is the one to watch. The moment it holds a repository that exists
nowhere else, this section stops being theoretical — mirror it to GitHub.

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

Each step depends on the one above it.

1. **Install Proxmox VE** on the new SSD. Node name must be `pve` or
   `dev.tfvars` needs updating.
2. **Prepare the host** — section 1: swap the enterprise repo for
   no-subscription, add the admin user, create `terraform@pve` with the
   `TerraformProv` role, issue an API token, create the `VM` and
   `Ubuntu-K8s` pools. Put the token in `dev.tfvars`.
3. **Build the cloud-init template** — section 2. It must be named whatever
   `clone_template_ubuntu` says.
4. **`terraform apply -var-file=dev.tfvars`** — six VMs.
5. **`ansible-playbook playbooks/nfs_server.yaml`** then `nfs_setup.yaml` —
   storage first, because everything else claims PVCs from it.
6. **`ansible-playbook playbooks/site.yaml`** — kubeadm cluster.
7. **`ansible-playbook playbooks/cluster_init.yaml`** and `join_workers.yaml`.
8. **`ansible-playbook playbooks/argocd-dev.yaml`** — ArgoCD via Helm. The
   UI login is `admin`, with the password whose bcrypt hash is
   `argocd_admin_password_hash` in `secret.yaml`. The play asserts that hash
   is present before installing, so a forgotten value fails here rather than
   leaving a random password in `argocd-initial-admin-secret`.
9. **`kubectl apply -f argocd/base/projects.yaml`** — the AppProject. Nothing
   has applied it yet at this point in a rebuild, so it must go on by hand;
   from here on, the `argocd-config` Application syncs it. This same command
   is also the only recovery if the AppProject is ever deleted from a running
   cluster: `argocd-config` declares `project: homelab`, so once that project
   is gone ArgoCD can no longer sync `argocd-config` either, and nothing is
   left that can recreate the AppProject except this manual apply.
10. **`kubectl apply -f argocd/environments/dev/applications/app-of-apps.yaml`**
    — `root-dev` then pulls in ingress-nginx, nfs, gitea, harbor, monitoring,
    jobboard.
11. **Create the jobboard Secrets** — ArgoCD syncs the jobboard manifests as
    soon as step 10 applies, but the app repo's `image` job only publishes
    `ghcr.io/maxim-grin/jobboard:latest` on a push to that repo's `main`, so
    merge order matters: merge the app repo to `main` first, wait for its
    `image` CI job to go green, *then* merge and push this repo. Applying
    these Secrets before the image exists just trades one CrashLoop for
    another.
    - `jobboard-secrets`: copy
      `argocd/apps/jobboard/base/secret.yaml.example` to `secret.yaml`
      (gitignored), fill it in, `kubectl apply -f` it.
    - `ghcr`, the image-pull secret for the private GHCR package:
      ```
      kubectl -n jobboard create secret docker-registry ghcr \
        --docker-server=ghcr.io \
        --docker-username=maxim-grin \
        --docker-password='<PAT with read:packages>'
      ```
      `create secret` rather than a manifest is deliberate: the token never
      touches a file that could be committed. The PAT needs scope
      `read:packages` and nothing else.
    Skip either one and the pod sits in `CreateContainerConfigError`
    (missing `jobboard-secrets`) or `ImagePullBackOff` (missing `ghcr`).
12. **`ansible-playbook playbooks/workstation.yaml`** — the workstation VM.
13. **`ansible-playbook playbooks/cluster_secrets.yaml`** — creates the
    `grafana-admin` Secret from `grafana_admin_password` in `secret.yaml`.
    Grafana's Deployment reads it through a `secretKeyRef` with no
    `optional: true`, so until this runs the pod sits in
    `CreateContainerConfigError`. Grafana applies the password only when it
    first creates its database; on an instance whose PVC already holds one,
    reset it explicitly with
    `kubectl -n monitoring exec deploy/grafana -- grafana-cli admin reset-admin-password <pw>`.
14. **Point `/etc/hosts`** at a node IP for `harbor.mgryn.cc`,
    `jobs.mgryn.cc`, `argocd.mgryn.cc`, `gitea.mgryn.cc`,
    `grafana.mgryn.cc` and `prometheus.mgryn.cc`. One line per name, all
    pointing at the same node -- ingress-nginx is a DaemonSet on host ports
    80/443, so any node answers.
    Gitea and Grafana each render absolute URLs from configuration
    (`GITEA__server__ROOT_URL`, `GF_SERVER_ROOT_URL`), so a name that does not
    resolve produces broken clone URLs and login redirects rather than a
    connection error.

Expect steps 9 and 10 to be the confusing ones: ArgoCD reads `main` from
GitHub, not the local checkout, so anything uncommitted is invisible to it.

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
3. **Store the ansible-vault password in a password manager** if it is not
   already there. This is the one that bites without warning: `secret.yaml`
   is committed and encrypted, so losing the password loses the file.
4. **Mirror Gitea to GitHub** once it holds anything.
5. **Export Grafana dashboards to git** once any are built.
