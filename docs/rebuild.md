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

**Two things to verify on the live host before a rebuild depends on this.**
They are recorded rather than silently corrected, because the cluster works
today and these notes disagree with the Terraform modules.

1. **Cloud-init drive bus.** The template attaches it at `ide2`;
   `proxmox/modules/ubuntu-vm/main.tf:64` declares the clone's cloud-init
   drive at `ide3`. A full clone inherits `ide2` from the template and the
   provider then configures `ide3`, so a VM could carry two. Since every VM
   here boots and takes its static address, whatever actually happens is
   benign — but nobody has looked. One command settles it:

   ```bash
   qm config 100 | grep -E '^(ide|scsi|agent|boot)'
   ```

   If only one cloud-init drive appears, the module and template agree in
   practice and this note can be deleted. If both appear, align the
   template to `ide3` so a rebuilt one behaves like the current one.

2. **QEMU guest agent.** These steps never install `qemu-guest-agent`, and
   stock Ubuntu cloud images do not ship it, yet the module sets
   `agent = 1` with `agent_timeout = 300`. That combination usually costs a
   long wait per VM while Proxmox queries an agent that never answers.
   Applies here have not visibly suffered, so check whether the guest
   actually has it:

   ```bash
   qm agent 100 ping && echo "agent responds"
   ```

   If it does not respond, either bake the agent into the image —

   ```bash
   apt-get install -y libguestfs-tools
   virt-customize -a noble-server-cloudimg-amd64.img --install qemu-guest-agent
   ```

   — or set `qemu_agent = 0` on the modules and accept that Terraform learns
   no IP from the guest. The static `ipconfig0` is what the modules use
   anyway.

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
8. **`ansible-playbook playbooks/argocd-dev.yaml`** — ArgoCD via Helm.
9. **`kubectl apply -f argocd/base/projects.yaml`** — the AppProject, which
   is not managed by ArgoCD itself and must be applied by hand.
10. **`kubectl apply -f argocd/environments/dev/applications/app-of-apps.yaml`**
    — `root-dev` then pulls in ingress-nginx, nfs, gitea, harbor, monitoring.
11. **`ansible-playbook playbooks/claude_code.yaml`** — the workstation VM.
12. **Point `/etc/hosts`** at a node IP for `harbor.mgryn.cc` and friends.

Expect steps 9 and 10 to be the confusing ones: ArgoCD reads `main` from
GitHub, not the local checkout, so anything uncommitted is invisible to it.

## Gaps worth closing before the disk is replaced

Roughly in order of how much they would hurt. None is urgent while the
cluster holds no data.

1. **Resolve the two template questions in section 2** — the `ide2`/`ide3`
   cloud-init slot and whether the guest agent is present. `qm config 100`
   and `qm agent 100 ping` answer both, and turn section 2 from
   notes-plus-caveats into a procedure. Best done while a working cluster
   still exists to compare against.
2. **Script the template build.** The commands above are a start; a
   `scripts/build-template.sh` would be better than a document that can drift.
3. **Store the ansible-vault password in a password manager** if it is not
   already there. This is the one that bites without warning: `secret.yaml`
   is committed and encrypted, so losing the password loses the file.
4. **Mirror Gitea to GitHub** once it holds anything.
5. **Export Grafana dashboards to git** once any are built.
