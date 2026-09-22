# Shared NFS Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `nfs-01` (vmid 103) out of the dev environment into a new `shared` Terraform root and Ansible inventory, serving two independent shares — `nfs-dev` and `nfs-prod` — each on its own virtual disk and exported only to its own nodes.

**Architecture:** A dedicated `proxmox/modules/nfs-server` (copied from `ubuntu-vm`, plus `scsi1`/`scsi2` data disks) is used by a new `proxmox/environments/shared` root that adopts the live VM with an `import` block, while dev drops it with a `removed { destroy = false }` block. The `nfs_server` Ansible role turns one export into a list of shares, each formatted, mounted by label, guarded against mounting over live data, and exported only when it has clients. The dev share keeps its path `/srv/nfs/k8s` because existing PVs have it baked in, so nothing on the cluster side changes.

**Tech Stack:** Terraform 1.16 + `telmate/proxmox` 3.0.2-rc10, tflint, Ansible (ansible-lint profile production, `community.general`, `ansible.posix`), nfs-kernel-server, kustomize.

**Spec:** `docs/superpowers/specs/2026-09-22-nfs-shared-server-design.md`

## Global Constraints

- Branch is `nfs-shared-server` (exists, holds the spec commit). Never commit to `main`, never merge, never push to `main`. The agent's job ends at an open PR.
- Commits: Conventional Commits, subject ≤ 50 chars, imperative, lowercase, no trailing period, body wrapped at 72. Types: `feat fix refactor docs chore ops`.
- **No `Co-Authored-By` trailer and no "generated with" line in commits or the PR body.** CLAUDE.md overrides any default attribution.
- vmid **103**, name `nfs`, IP `10.0.0.131`, pool `VM`, 2 cores, 2048 MB, OS disk `20G`, data disks `50G` (dev, `scsi1`) and `50G` (prod, `scsi2`), storage `local-lvm`, `start_at_node_boot = true`, `startup = "order=10,up=30"`.
- Dev share path is **`/srv/nfs/k8s`**. Prod share path is **`/srv/nfs/prod`**. Never rename the dev path.
- Export options: `rw,sync,no_subtree_check,no_root_squash`. Dev clients: `master-01`, `worker-01`, `worker-02` from `host_ips`. Prod clients: `[]`.
- A share with no clients gets **no** `/etc/exports` line. No `nofail` in `fstab`.
- `proxmox/environments/prod` main.tf and `talos/` are not touched. The only prod change is the provisioner placeholders.
- No plan may ever apply a Terraform plan that destroys or replaces vmid 103.
- `ansible/secret.yaml` is ciphertext: never decrypt it, never pass it in agent-run commands. `*.tfvars` never committed.
- Tools on this box: `terraform`, `tflint`, `kubectl`, `ansible-lint` on PATH. `ansible` and `ansible-playbook` are not on PATH; use `ANSIBLE_BIN=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin`.
- Terraform applies, playbook runs against real hosts, and the data migration are operator steps (Task 9), run by the repository owner. Agents never run `terraform apply`, `terraform plan` against Proxmox, or a playbook against a real host.
- Read narrowly: `grep -n`, `sed -n`, `head`/`tail`. Do not `cat` whole files to inspect part of them.

## File Map

| File | Change | Responsibility |
| --- | --- | --- |
| `proxmox/modules/nfs-server/{versions,variables,main,outputs}.tf` | create | The NFS VM with two data disks |
| `proxmox/environments/shared/{versions,variables,main,outputs}.tf` | create | Root that owns `nfs-01` |
| `proxmox/environments/shared/{shared.tfvars.example,backend.tf.example}` | create | Committed templates for gitignored files |
| `proxmox/environments/shared/.terraform.lock.hcl` | create | Copy of dev's lock file, same provider pin |
| `proxmox/environments/dev/{main,outputs,variables}.tf`, `dev.tfvars.example` | modify | Drop `module "nfs"`, add `removed` |
| `.github/workflows/ci.yaml` | modify | Validate and lint `shared/` too |
| `ansible/inventories/shared/hosts.yaml` | create | Inventory holding `nfs-01` |
| `ansible/inventories/dev/hosts.yaml` | modify | Drop the `nfs` group |
| `ansible/roles/nfs_server/{defaults,tasks,templates,handlers}` | modify | Shares list, disks, guard, mounts, exports |
| `argocd/apps/nfs_provisioner/prod/deployment.yaml` | modify | Real server and path |
| `docs/rebuild.md`, `CLAUDE.md`, `proxmox/README.md`, `ansible/README.md` | modify | Where NFS lives now |

---

### Task 1: `nfs-server` Terraform module

**Files:**
- Create: `proxmox/modules/nfs-server/versions.tf`
- Create: `proxmox/modules/nfs-server/variables.tf`
- Create: `proxmox/modules/nfs-server/main.tf`
- Create: `proxmox/modules/nfs-server/outputs.tf`
- Reference (read, do not modify): `proxmox/modules/ubuntu-vm/main.tf`

**Interfaces:**
- Produces: module `nfs-server` with resource `proxmox_vm_qemu.nfs_server`; inputs `vm_name, target_node, vmid, pool, clone_template, full_clone, memory, cpu_cores, start_at_node_boot, startup, disk_size, nfs_dev_disk_size, nfs_prod_disk_size, disk_storage, cloudinit_storage, network_bridge, network_firewall, ci_user, ci_password, ssh_public_key, ip_config, tags`; outputs `vm_id, vm_name, vm_mac, vm_ip_config`.

The VM already exists and was created by `ubuntu-vm`. Every setting that `ubuntu-vm` hard-codes (machine, CPU type, scsi0 disk flags, ide3 cloud-init, serial, network) must be copied **exactly** — a difference is drift the import will try to "fix", and some differences force replacement.

- [ ] **Step 1: Write `versions.tf`**

```hcl
terraform {
  required_version = "~> 1.16.0"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc10"
    }
  }
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
# VM Basic Configuration
variable "vm_name" {
  description = "Name of the VM"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to deploy VM on"
  type        = string
}

variable "vmid" {
  description = "VM ID (must be unique)"
  type        = number
}

variable "pool" {
  description = "Resource pool for the VM"
  type        = string
  default     = null
}

# Clone Configuration
variable "clone_template" {
  description = "Template to clone from"
  type        = string
}

variable "full_clone" {
  description = "Whether to perform a full clone"
  type        = bool
}

# Resource Allocation
variable "memory" {
  description = "Memory allocation in MB"
  type        = number
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
}

# Boot Configuration
variable "start_at_node_boot" {
  description = "Start VM on boot"
  type        = bool
}

# Proxmox startup order. Guests start low-order first; "up" is the delay in
# seconds before the next one begins. Every PVC in every cluster binds
# through this host, so it starts ahead of them.
variable "startup" {
  description = "Startup order and delay (e.g., 'order=10,up=30')"
  type        = string
  default     = null
}

# Disk Configuration
variable "disk_size" {
  description = "OS disk size (e.g., '20G')"
  type        = string
}

# One disk per share, so one environment filling its share cannot stop the
# other writing. Sizes only go up: Proxmox cannot shrink a disk.
variable "nfs_dev_disk_size" {
  description = "Size of the nfs-dev data disk (scsi1)"
  type        = string
}

variable "nfs_prod_disk_size" {
  description = "Size of the nfs-prod data disk (scsi2)"
  type        = string
}

variable "disk_storage" {
  description = "Storage location for all three disks"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_storage" {
  description = "Storage for cloud-init disk"
  type        = string
  default     = "local-lvm"
}

# Network Configuration
variable "network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "network_firewall" {
  description = "Enable firewall on network interface"
  type        = bool
  default     = true
}

# Cloud-init Settings
variable "ci_user" {
  description = "Cloud-init user"
  type        = string
}

variable "ci_password" {
  description = "Cloud-init password"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for adding it to authorized keys"
  type        = string
  default     = ""
}

variable "ip_config" {
  description = "IP configuration (ipconfig0)"
  type        = string
}

# Tags
variable "tags" {
  description = "VM tags"
  type        = string
  default     = "ubuntu,nfs"
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
# A copy of modules/ubuntu-vm with two data disks. nfs-01 was created by
# ubuntu-vm and adopted with an import block, so every hard-coded setting
# below must stay identical to ubuntu-vm's: a difference is drift the next
# plan tries to correct, and some of it forces a replacement.
resource "proxmox_vm_qemu" "nfs_server" {
  name        = var.vm_name
  target_node = var.target_node
  vmid        = var.vmid
  pool        = var.pool
  power_state = "running"

  # Attaching the data disks must not reboot the VM out from under every
  # mounted PVC. A change that needs a reboot is left pending instead.
  automatic_reboot = false

  lifecycle {
    ignore_changes = [
      power_state,
      # An imported VM need not report the template it was cloned from, and
      # a clone mismatch plans a replacement -- which destroys the OS disk.
      clone,
      full_clone,
    ]
  }

  # Clone settings
  clone      = var.clone_template
  full_clone = var.full_clone

  # Resource allocation
  memory = var.memory
  cpu {
    cores   = var.cpu_cores
    limit   = 0
    numa    = false
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  # System settings
  machine = "q35"
  qemu_os = "l26"
  scsihw  = "virtio-scsi-single"

  # Boot and startup
  boot               = "order=scsi0"
  start_at_node_boot = var.start_at_node_boot
  startup            = var.startup

  # Agent and connection settings
  agent                  = 1
  define_connection_info = true
  clone_wait             = 10
  additional_wait        = 5
  agent_timeout          = 300
  skip_ipv6              = true

  # Disk configuration. scsi1 and scsi2 appear in the guest as
  # /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi{1,2}; the
  # nfs_server Ansible role finds them by those names.
  disks {
    scsi {
      scsi0 {
        disk {
          size       = var.disk_size
          storage    = var.disk_storage
          format     = "raw"
          iothread   = true
          discard    = true
          cache      = "none"
          backup     = true
          emulatessd = true
          readonly   = false
          replicate  = true
        }
      }
      scsi1 {
        disk {
          size       = var.nfs_dev_disk_size
          storage    = var.disk_storage
          format     = "raw"
          iothread   = true
          discard    = true
          cache      = "none"
          backup     = true
          emulatessd = true
          readonly   = false
          replicate  = true
        }
      }
      scsi2 {
        disk {
          size       = var.nfs_prod_disk_size
          storage    = var.disk_storage
          format     = "raw"
          iothread   = true
          discard    = true
          cache      = "none"
          backup     = true
          emulatessd = true
          readonly   = false
          replicate  = true
        }
      }
    }
    ide {
      ide3 {
        cloudinit {
          storage = var.cloudinit_storage
        }
      }
    }
  }

  # Network configuration
  network {
    id        = 0
    model     = "virtio"
    bridge    = var.network_bridge
    firewall  = var.network_firewall
    link_down = false
  }

  # Serial console
  serial {
    id   = 0
    type = "socket"
  }

  # Cloud-init settings
  ciuser     = var.ci_user
  cipassword = var.ci_password
  sshkeys    = var.ssh_public_key
  ipconfig0  = var.ip_config

  # Tags
  tags = var.tags
}
```

- [ ] **Step 4: Write `outputs.tf`**

```hcl
output "vm_id" {
  description = "The ID of the NFS server VM"
  value       = proxmox_vm_qemu.nfs_server.vmid
}

output "vm_name" {
  description = "The name of the NFS server VM"
  value       = proxmox_vm_qemu.nfs_server.name
}

output "vm_mac" {
  description = "The MAC address of the VM's network interface"
  value       = proxmox_vm_qemu.nfs_server.network[0].macaddr
}

output "vm_ip_config" {
  description = "The IP configuration of the VM"
  value       = proxmox_vm_qemu.nfs_server.ipconfig0
}
```

- [ ] **Step 5: Diff the hard-coded settings against `ubuntu-vm`**

Run: `diff <(sed -n '/^  # System settings/,/^  # Tags/p' proxmox/modules/ubuntu-vm/main.tf) <(sed -n '/^  # System settings/,/^  # Tags/p' proxmox/modules/nfs-server/main.tf)`

Expected: the only differences are `boot = var.boot_order` → `"order=scsi0"`, `agent = var.qemu_agent` → `1`, `model = var.network_model` → `"virtio"`, the removed `cicustom` lines, the disk comment, and the added `scsi1`/`scsi2` blocks. Anything else is a copy error: fix it.

- [ ] **Step 6: Validate the module**

Run: `cd proxmox/modules/nfs-server && terraform init -backend=false -input=false >/dev/null && terraform validate && terraform fmt -check && tflint --config=/home/ubuntu/homelab/.tflint.hcl; rm -rf .terraform .terraform.lock.hcl`

Expected: `Success! The configuration is valid.`, no fmt output, no tflint findings. If `automatic_reboot` is rejected as unsupported, stop and report it — do not delete the line silently; the supervisor decides.

- [ ] **Step 7: Commit**

```bash
git add proxmox/modules/nfs-server
git commit -m "feat: add nfs-server terraform module" -m "A copy of ubuntu-vm with scsi1 and scsi2 data disks, one per share,
for adopting nfs-01 into its own root."
```

---

### Task 2: `shared` Terraform root and CI

**Files:**
- Create: `proxmox/environments/shared/versions.tf`
- Create: `proxmox/environments/shared/variables.tf`
- Create: `proxmox/environments/shared/main.tf`
- Create: `proxmox/environments/shared/outputs.tf`
- Create: `proxmox/environments/shared/shared.tfvars.example`
- Create: `proxmox/environments/shared/backend.tf.example`
- Create: `proxmox/environments/shared/.terraform.lock.hcl` (copy)
- Modify: `.github/workflows/ci.yaml:115-120`

**Interfaces:**
- Consumes: module `../../modules/nfs-server` from Task 1, resource address `module.nfs.proxmox_vm_qemu.nfs_server`.
- Produces: root `proxmox/environments/shared` with output `nfs_vm_details { id, name, mac, ip }`; variables `pm_target_node, pm_api_url, pm_api_token_id, pm_api_token_secret, ci_user, ci_password, ssh_public_key, clone_template_ubuntu, gateway, nfs_vm_ip`.

- [ ] **Step 1: Write `versions.tf`** — identical to `proxmox/environments/dev/versions.tf`:

```hcl
terraform {
  required_version = "~> 1.16.0"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc10"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
# ProxMox Variables
variable "pm_target_node" {
  description = "Proxmox Target Node"
  type        = string
}

variable "pm_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API Token ID"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
}

# Cloud-init. Must match dev.tfvars: nfs-01 was created with these values,
# and a different password or key shows up as drift on the imported VM.
variable "ci_user" {
  description = "Cloud-init user"
  type        = string
}

variable "ci_password" {
  description = "Cloud-init password"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for adding it to authorized keys"
  type        = string
  default     = ""
}

variable "clone_template_ubuntu" {
  description = "Ubuntu cloud-init template every VM clones"
  type        = string
}

variable "gateway" {
  description = "Default gateway for static IPs"
  type        = string
}

# NFS Server VM Variables
variable "nfs_vm_ip" {
  description = "NFS server VM IP with CIDR (e.g. '10.0.0.131/24')"
  type        = string
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
################################################################################
# Shared infrastructure: machines no single environment owns.
#
# nfs-01 serves both nfs-dev and nfs-prod, so neither environment's apply may
# change or destroy it. It lived in environments/dev until 2026-09 and was
# adopted here with an import block; dev dropped it with a removed block.
################################################################################

################################################################################
# NFS Server
################################################################################
module "nfs" {
  source = "../../modules/nfs-server"

  # Basic VM Configuration
  vm_name     = "nfs"
  vmid        = 103
  target_node = var.pm_target_node
  pool        = "VM"

  clone_template = var.clone_template_ubuntu
  full_clone     = true

  # Resource Allocation
  # It only serves files; nfsd is kernel-side and needs almost nothing here.
  memory    = 2048
  cpu_cores = 2

  # OS disk, then one disk per share. nfs-subdir-external-provisioner does
  # not enforce PVC sizes, so a share can grow until its disk is full; 50G
  # covers what the dev PVCs request today.
  disk_size          = "20G"
  nfs_dev_disk_size  = "50G"
  nfs_prod_disk_size = "50G"
  disk_storage       = "local-lvm"

  # Start automatically: every PVC in every cluster binds through this host.
  # Order 10, ahead of the dev cluster (master order=20, workers order=30 in
  # environments/dev): when the provisioner is down every PVC without an
  # explicit class sits Pending and the apps above it read as broken for
  # unrelated reasons.
  start_at_node_boot = true
  startup            = "order=10,up=30"

  # Network Configuration
  network_firewall = true
  ip_config        = format("ip=%s,gw=%s", var.nfs_vm_ip, var.gateway)

  # Cloud-init Settings
  ci_user        = var.ci_user
  ci_password    = var.ci_password
  ssh_public_key = var.ssh_public_key

  # OS configuration lives in the ansible/ nfs_server role, run against
  # ansible/inventories/shared.

  # Tags
  tags = "ubuntu,nfs,shared"
}

# Adopts the existing nfs-01 instead of creating a new one. Remove this block
# once the first apply has imported it: on a rebuilt host vmid 103 does not
# exist yet, and an import of a missing VM fails the plan.
import {
  to = module.nfs.proxmox_vm_qemu.nfs_server
  id = "${var.pm_target_node}/qemu/103"
}
```

Note the tag changes from `ubuntu,nfs,dev` to `ubuntu,nfs,shared`. That is an intended in-place update the Task 9 plan will show.

- [ ] **Step 4: Write `outputs.tf`**

```hcl
# NFS Server VM Output
output "nfs_vm_details" {
  value = {
    id   = module.nfs.vm_id
    name = module.nfs.vm_name
    mac  = module.nfs.vm_mac
    ip   = module.nfs.vm_ip_config
  }
}
```

- [ ] **Step 5: Write `shared.tfvars.example`**

```hcl
# Copy to shared.tfvars and fill in. shared.tfvars is gitignored (*.tfvars)
# and has no backup anywhere -- see docs/rebuild.md before you need it.
#
# Every value here also appears in dev.tfvars. Copy them from there rather
# than re-typing: nfs-01 was created from dev.tfvars, and a different
# ci_password or ssh_public_key is drift on the imported VM.

# Proxmox
pm_target_node      = "pve"
pm_api_url          = "https://<PROXMOX_IP>:8006/api2/json"
pm_api_token_id     = "root@pam!terraform"
pm_api_token_secret = "<UUID>"

# Cloud-init user
ci_user        = "ubuntu"
ci_password    = "<PASSWORD>"
ssh_public_key = "ssh-ed25519 AAAA... homelab-dev"

# Template that must already exist on the host; docs/rebuild.md has the qm
# commands that build it.
clone_template_ubuntu = "ubuntu-cid-tp"

gateway = "10.0.0.1"

# NFS server VM. Must include CIDR.
nfs_vm_ip = "10.0.0.131/24"
```

- [ ] **Step 6: Write `backend.tf.example`** and copy the lock file

```hcl
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
```

Run: `cp proxmox/environments/dev/.terraform.lock.hcl proxmox/environments/shared/.terraform.lock.hcl`

- [ ] **Step 7: Confirm the gitignore rules match the new files**

Run: `for f in shared.tfvars backend.tf terraform.tfstate terraform.tfstate.backup .terraform/x; do git check-ignore -v proxmox/environments/shared/$f || echo "NOT IGNORED: $f"; done`

Expected: five lines naming a `.gitignore` rule, no `NOT IGNORED`. If any is not ignored, stop and report — do not add a rule without the supervisor.

- [ ] **Step 8: Validate the root**

Run: `cd proxmox/environments/shared && terraform init -backend=false -input=false >/dev/null && terraform validate && terraform fmt -check && tflint --config=/home/ubuntu/homelab/.tflint.hcl; rm -rf .terraform`

Then: `diff proxmox/environments/dev/.terraform.lock.hcl proxmox/environments/shared/.terraform.lock.hcl`

Expected: `Success! The configuration is valid.`, no fmt or tflint output, and an empty `diff` — `init` did not rewrite the copied lock file.

- [ ] **Step 9: Add `shared/` to the CI terraform job**

In `.github/workflows/ci.yaml`, replace:

```yaml
      - name: terraform init and validate
        run: |
          terraform -chdir=proxmox/environments/dev init -backend=false -input=false
          terraform -chdir=proxmox/environments/dev validate
      - name: tflint
        run: tflint --chdir=proxmox/environments/dev --config="${GITHUB_WORKSPACE}/.tflint.hcl"
```

with:

```yaml
      - name: terraform init and validate
        run: |
          for env in dev shared; do
            terraform -chdir=proxmox/environments/$env init -backend=false -input=false
            terraform -chdir=proxmox/environments/$env validate
          done
      - name: tflint
        run: |
          for env in dev shared; do
            tflint --chdir=proxmox/environments/$env --config="${GITHUB_WORKSPACE}/.tflint.hcl"
          done
```

- [ ] **Step 10: Run pre-commit on the changed files**

Run: `pre-commit run --files .github/workflows/ci.yaml proxmox/environments/shared/*.tf proxmox/environments/shared/*.example`

Expected: all hooks Passed or Skipped.

- [ ] **Step 11: Commit**

```bash
git add proxmox/environments/shared .github/workflows/ci.yaml
git commit -m "feat: add shared terraform root for nfs-01" -m "Adopts vmid 103 with an import block so neither dev nor prod applies
own the server both depend on. CI validates and lints it alongside dev."
```

---

### Task 3: Drop `nfs-01` from the dev root

**Files:**
- Modify: `proxmox/environments/dev/main.tf:118-126` (comments), `:183-232` (module "nfs")
- Modify: `proxmox/environments/dev/outputs.tf:56-64`
- Modify: `proxmox/environments/dev/variables.tf:128-132`
- Modify: `proxmox/environments/dev/dev.tfvars.example` (the `nfs_vm_ip` lines)

**Interfaces:**
- Consumes: nothing from earlier tasks. Must not reference `proxmox/environments/shared`.
- Produces: dev root with no `module.nfs`, no output `nfs_vm_details`, no variable `nfs_vm_ip`, and a `removed { from = module.nfs }` block.

- [ ] **Step 1: Confirm nothing else in dev references the module or variable**

Run: `grep -n -E "module\.nfs|nfs_vm_ip|nfs_vm_details" proxmox/environments/dev/*.tf proxmox/environments/dev/*.example`

Expected: only `main.tf` (the module block's own `var.nfs_vm_ip` lines), `outputs.tf:56-64`, `variables.tf:128-132`, `dev.tfvars.example`. Any other hit: stop and report.

- [ ] **Step 2: Replace the module block**

In `proxmox/environments/dev/main.tf`, delete everything from the `# NFS Server` banner (the `####` line above it through the closing `}` of `module "nfs"`, including its trailing blank line) and put in its place:

```hcl
################################################################################
# NFS Server -- moved to environments/shared
################################################################################
# nfs-01 serves both nfs-dev and nfs-prod, so it is owned by
# proxmox/environments/shared. destroy = false drops it from this state
# without touching the VM. Delete this block once `terraform apply` here has
# run with it once.
removed {
  from = module.nfs

  lifecycle {
    destroy = false
  }
}
```

- [ ] **Step 3: Update the startup-order comment**

In `proxmox/environments/dev/main.tf`, replace:

```hcl
  # Master ahead of the workers, with 60s for the API server to answer before
  # kubelets start trying to reach it. Both after nfs-01 at order=10.
```

with:

```hcl
  # Master ahead of the workers, with 60s for the API server to answer before
  # kubelets start trying to reach it. Both after nfs-01 at order=10, which
  # lives in proxmox/environments/shared.
```

- [ ] **Step 4: Delete the output, the variable and the example lines**

- `outputs.tf`: delete the `# NFS Server VM Output` comment and the whole `output "nfs_vm_details"` block, plus one of the surrounding blank lines.
- `variables.tf`: delete the `# NFS Server VM Variables` comment and the whole `variable "nfs_vm_ip"` block, plus one of the surrounding blank lines.
- `dev.tfvars.example`: delete these two lines and the blank line after them:

```hcl
# NFS server VM. Must include CIDR.
nfs_vm_ip = "10.0.0.131/24"
```

A leftover `nfs_vm_ip` in a real `dev.tfvars` only produces an "undeclared variable" warning, not an error; Task 9 tells the operator to delete it.

- [ ] **Step 5: Validate dev**

Run: `cd proxmox/environments/dev && terraform init -backend=false -input=false >/dev/null && terraform validate && terraform fmt -check && tflint --config=/home/ubuntu/homelab/.tflint.hcl; cd /home/ubuntu/homelab && git status --short proxmox/environments/dev`

Expected: `Success! The configuration is valid.`, no fmt or tflint output, and git status lists exactly `main.tf`, `outputs.tf`, `variables.tf`, `dev.tfvars.example` as modified — `.terraform.lock.hcl` unchanged.

- [ ] **Step 6: Commit**

```bash
git add proxmox/environments/dev
git commit -m "refactor: drop nfs-01 from the dev terraform root" -m "A removed block with destroy = false releases vmid 103 from dev state
without touching the VM; environments/shared imports it."
```

---

### Task 4: Shared Ansible inventory

**Files:**
- Create: `ansible/inventories/shared/hosts.yaml`
- Modify: `ansible/inventories/dev/hosts.yaml:27-31`

**Interfaces:**
- Consumes: `host_ips['nfs-01']`, `proxmox_vm_ids['nfs-01']`, `user_name`, `ssh_private_key` from `ansible/secret.yaml` (passed at run time by the operator, never by the agent).
- Produces: inventory `inventories/shared` with group `nfs` holding host `nfs-01`. `playbooks/nfs_server.yaml` (`hosts: nfs`) runs against it unchanged.

- [ ] **Step 1: Write `ansible/inventories/shared/hosts.yaml`**

```yaml
# Machines no single environment owns. nfs-01 serves both nfs-dev and
# nfs-prod, so it is here rather than in inventories/dev or
# inventories/prod. Run its playbook with -i inventories/shared; ansible.cfg
# defaults to inventories/dev, where nfs-01 no longer is.
all:
  vars:
    ansible_user: "{{ user_name }}"
    ansible_private_key_file: "{{ ssh_private_key }}"
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    nfs:
      hosts:
        nfs-01:
          ansible_host: "{{ host_ips['nfs-01'] }}"
          proxmox_vm_id: "{{ proxmox_vm_ids['nfs-01'] }}"
```

- [ ] **Step 2: Remove the `nfs` group from dev**

In `ansible/inventories/dev/hosts.yaml`, delete these lines:

```yaml
    nfs:
      hosts:
        nfs-01:
          ansible_host: "{{ host_ips['nfs-01'] }}"
          proxmox_vm_id: "{{ proxmox_vm_ids['nfs-01'] }}"
```

- [ ] **Step 3: Check both inventories parse and hold the right hosts**

Run: `cd ansible && $ANSIBLE_BIN/ansible-inventory -i inventories/shared --graph && $ANSIBLE_BIN/ansible-inventory -i inventories/dev --graph`

(with `ANSIBLE_BIN=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin`)

Expected: shared shows `@nfs:` → `nfs-01` and nothing else; dev shows `k8s_cluster`, `claude_code`, `vault` and no `nfs` group or `nfs-01`.

- [ ] **Step 4: Syntax-check the server playbook against the new inventory**

Run: `cd ansible && $ANSIBLE_BIN/ansible-playbook -i inventories/shared playbooks/nfs_server.yaml --syntax-check`

Expected: `playbook: playbooks/nfs_server.yaml`. No `secret.yaml` is needed for a syntax check.

- [ ] **Step 5: Lint**

Run: `cd ansible && ansible-lint .`

Expected: `Passed: 0 failure(s), 0 warning(s)` at profile production.

- [ ] **Step 6: Commit**

```bash
git add ansible/inventories
git commit -m "refactor: move nfs-01 to a shared ansible inventory"
```

---

### Task 5: `nfs_server` role — shares on their own disks

**Files:**
- Modify: `ansible/roles/nfs_server/defaults/main.yaml` (full rewrite)
- Modify: `ansible/roles/nfs_server/tasks/main.yaml` (full rewrite)
- Modify: `ansible/roles/nfs_server/templates/exports.j2` (full rewrite)
- Create: `ansible/roles/nfs_server/templates/requires-mounts.conf.j2`
- Test (scratchpad, not committed): `$SCRATCH/exports-test.yaml`, where `SCRATCH` is the session scratchpad directory

**Interfaces:**
- Consumes: `host_ips` (dict, from `secret.yaml`); devices `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1` and `...-scsi2` from Task 1's disks; `ansible_facts.mounts` (the playbook sets `gather_facts: true`).
- Produces: variables `nfs_server_shares` (list of `{name, device, path, clients}`), `nfs_server_dev_nodes`, `nfs_server_dev_clients`, `nfs_server_prod_clients`, `nfs_server_export_options`. Filesystem labels `nfs-dev`, `nfs-prod`. Removes `nfs_server_export_path` and `nfs_server_export_clients` — confirm nothing else uses them in Step 1.

- [ ] **Step 1: Confirm the old variables are used only inside the role**

Run: `grep -rn -E "nfs_server_export_(path|clients)" ansible argocd docs proxmox README.md CLAUDE.md | grep -v "^ansible/roles/nfs_server/"`

Expected: no output. Any hit: stop and report.

- [ ] **Step 2: Write the failing template test**

Create `$SCRATCH/exports-test.yaml`:

```yaml
- name: Render exports.j2 against the new share model
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - /home/ubuntu/homelab/ansible/roles/nfs_server/defaults/main.yaml
  vars:
    host_ips:
      master-01: 10.0.0.120
      worker-01: 10.0.0.121
      worker-02: 10.0.0.122
  tasks:
    - name: Render
      ansible.builtin.set_fact:
        rendered: "{{ lookup('ansible.builtin.template', '/home/ubuntu/homelab/ansible/roles/nfs_server/templates/exports.j2') }}"

    - name: Dev line lists each node with the options, prod has no line
      ansible.builtin.assert:
        that:
          - "'/srv/nfs/k8s 10.0.0.120(rw,sync,no_subtree_check,no_root_squash) 10.0.0.121(rw,sync,no_subtree_check,no_root_squash) 10.0.0.122(rw,sync,no_subtree_check,no_root_squash)' in rendered.splitlines()"
          - "'/srv/nfs/prod' not in rendered"
          - "rendered.splitlines() | reject('match', '^#') | reject('equalto', '') | list | length == 1"
        fail_msg: "{{ rendered }}"

    - name: A share with clients gets a line
      ansible.builtin.assert:
        that:
          - "'/srv/nfs/prod 10.0.0.200(rw,sync,no_subtree_check,no_root_squash)' in lookup('ansible.builtin.template', '/home/ubuntu/homelab/ansible/roles/nfs_server/templates/exports.j2', template_vars={'nfs_server_shares': [{'name': 'prod', 'path': '/srv/nfs/prod', 'clients': ['10.0.0.200']}]}).splitlines()"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `$ANSIBLE_BIN/ansible-playbook -i localhost, $SCRATCH/exports-test.yaml`

Expected: FAIL — the old template renders `/srv/nfs/k8s 10.0.0.0/24(...)` from `nfs_server_export_path`, so the first assertion fails.

- [ ] **Step 4: Rewrite `defaults/main.yaml`**

```yaml
---
# Default values for the NFS server role

# One entry per share, each on its own virtual disk (scsi1, scsi2 in
# proxmox/modules/nfs-server), so one environment filling its share cannot
# stop the other writing. Disks are found by their Proxmox slot, which does
# not change between boots the way /dev/sdX can.
#
# The dev path is /srv/nfs/k8s, not /srv/nfs/dev, and must stay that way:
# every existing PV carries nfs.path: /srv/nfs/k8s/<ns>-<pvc>-<pv>, that
# field is immutable, and nfs-dev deletes a volume's data when its PVC goes.
# Renaming it means hand-recreating every PV.
nfs_server_shares:
  - name: dev
    device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
    path: /srv/nfs/k8s
    clients: "{{ nfs_server_dev_clients }}"
  - name: prod
    device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2
    path: /srv/nfs/prod
    clients: "{{ nfs_server_prod_clients }}"

# Exact node addresses, not the subnet: a dev pod cannot mount prod data even
# by mistake. Names are keys of host_ips in secret.yaml.
nfs_server_dev_nodes:
  - master-01
  - worker-01
  - worker-02
nfs_server_dev_clients: "{{ nfs_server_dev_nodes | map('extract', host_ips) | list }}"

# Empty until a prod cluster exists. An empty list means no export line at
# all -- see templates/exports.j2.
nfs_server_prod_clients: []

# no_root_squash is required, not lazy: nfs-subdir-external-provisioner
# creates a directory per PersistentVolume and chowns it. With root squashed
# to nobody those chowns fail and every PVC stays Pending.
nfs_server_export_options: rw,sync,no_subtree_check,no_root_squash
```

- [ ] **Step 5: Rewrite `templates/exports.j2`**

```jinja
# Managed by ansible (roles/nfs_server). Manual edits will be overwritten.
# A share with no clients gets no line: an export with no client list is
# exported to every host.
{% for share in nfs_server_shares if share.clients | length > 0 %}
{{ share.path }} {% for client in share.clients %}{{ client }}({{ nfs_server_export_options }}){{ ' ' if not loop.last }}{% endfor %}

{% endfor %}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `$ANSIBLE_BIN/ansible-playbook -i localhost, $SCRATCH/exports-test.yaml`

Expected: `ok=3 ... failed=0`. If the line assertion fails on whitespace, print `rendered` from `fail_msg` and fix the template, not the test.

- [ ] **Step 7: Write `templates/requires-mounts.conf.j2`**

```jinja
# Managed by ansible (roles/nfs_server).
# nfs-server does not start until every share's disk is mounted. Without
# this, a disk that fails to mount leaves the empty directory underneath it
# exported, and PVC writes land silently on the OS disk.
[Unit]
RequiresMountsFor={{ nfs_server_shares | map(attribute='path') | join(' ') }}
```

- [ ] **Step 8: Rewrite `tasks/main.yaml`**

```yaml
---
- name: Install the NFS server package
  ansible.builtin.apt:
    name: nfs-kernel-server
    state: present
    update_cache: true

- name: Look for files at each share's mount point
  ansible.builtin.find:
    paths: "{{ item.path }}"
    file_type: any
    hidden: true
  register: nfs_server_mount_point_contents
  loop: "{{ nfs_server_shares }}"
  loop_control:
    label: "{{ item.path }}"

# Mounting a disk over a directory that already holds data hides that data
# from every client. On the first run after the disks are attached, dev's
# PVCs are still on the OS disk at /srv/nfs/k8s; this stops the play before
# the empty new disk goes over them. Move the data first -- the Migration
# section of docs/superpowers/specs/2026-09-22-nfs-shared-server-design.md.
- name: Refuse to mount over files that are not on the share's own disk
  ansible.builtin.assert:
    that: >-
      item.matched == 0 or
      item.item.path in (ansible_facts.mounts | map(attribute='mount') | list)
    fail_msg: >-
      {{ item.item.path }} holds files but is not a mount point. Mounting the
      {{ item.item.name }} disk there would hide them. Move them onto the
      disk first.
    quiet: true
  loop: "{{ nfs_server_mount_point_contents.results }}"
  loop_control:
    label: "{{ item.item.path }}"

- name: Create each share's filesystem
  community.general.filesystem:
    dev: "{{ item.device }}"
    fstype: ext4
    opts: "-L nfs-{{ item.name }}"
  loop: "{{ nfs_server_shares }}"
  loop_control:
    label: "{{ item.name }}"

# By label, not device path, so fstab survives a disk moving slots. No
# nofail: a missing disk should stop the boot's NFS, not be exported empty.
- name: Mount each share's disk
  ansible.posix.mount:
    path: "{{ item.path }}"
    src: "LABEL=nfs-{{ item.name }}"
    fstype: ext4
    opts: defaults
    state: mounted
  loop: "{{ nfs_server_shares }}"
  loop_control:
    label: "{{ item.path }}"

- name: Open each share's root to the provisioner
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    # 0777 with no_root_squash: the provisioner creates a subdirectory per
    # PersistentVolume as root and the workloads that mount them run as
    # arbitrary uids. Tightening this breaks PVC provisioning.
    mode: "0777"
  loop: "{{ nfs_server_shares }}"
  loop_control:
    label: "{{ item.path }}"

- name: Create the nfs-server drop-in directory
  ansible.builtin.file:
    path: /etc/systemd/system/nfs-server.service.d
    state: directory
    mode: "0755"

- name: Hold nfs-server until every share's disk is mounted
  ansible.builtin.template:
    src: requires-mounts.conf.j2
    dest: /etc/systemd/system/nfs-server.service.d/requires-mounts.conf
    mode: "0644"

- name: Write /etc/exports
  ansible.builtin.template:
    src: exports.j2
    dest: /etc/exports
    mode: "0644"
  notify: Reload exports

# daemon_reload picks up the drop-in before the start.
- name: Enable and start the NFS server
  ansible.builtin.systemd_service:
    name: nfs-server
    enabled: true
    state: started
    daemon_reload: true

- name: Confirm the export is published
  ansible.builtin.command: showmount -e localhost
  register: nfs_server_exports
  changed_when: false

- name: Show the published exports
  ansible.builtin.debug:
    msg: "{{ nfs_server_exports.stdout_lines }}"
```

`handlers/main.yaml` is unchanged (`exportfs -ra`).

- [ ] **Step 9: Test the guard's expression against both cases**

Append to `$SCRATCH/exports-test.yaml` a second play:

```yaml
- name: Guard expression
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    mounts: [{mount: /}, {mount: /srv/nfs/prod}]
    expr: "{{ item.matched == 0 or item.item.path in (mounts | map(attribute='mount') | list) }}"
  tasks:
    - name: Non-empty and not mounted is refused; the other cases pass
      ansible.builtin.assert:
        that: "(item.matched == 0 or item.item.path in (mounts | map(attribute='mount') | list)) == item.want"
      loop:
        - {matched: 5, item: {path: /srv/nfs/k8s}, want: false}
        - {matched: 0, item: {path: /srv/nfs/k8s}, want: true}
        - {matched: 5, item: {path: /srv/nfs/prod}, want: true}
```

Run: `$ANSIBLE_BIN/ansible-playbook -i localhost, $SCRATCH/exports-test.yaml`

Expected: all assertions pass, `failed=0`. This expression must match the one in the role's assert task character for character; if you change one, change both.

- [ ] **Step 10: Lint and syntax-check**

Run: `cd ansible && ansible-lint . && $ANSIBLE_BIN/ansible-playbook -i inventories/shared playbooks/nfs_server.yaml --syntax-check`

Expected: `Passed: 0 failure(s), 0 warning(s)`; `playbook: playbooks/nfs_server.yaml`.

- [ ] **Step 11: Commit**

```bash
git add ansible/roles/nfs_server
git commit -m "feat: serve nfs-dev and nfs-prod from own disks" -m "Each share is formatted, mounted by label and exported only to its
own nodes. The role refuses to mount over a non-empty directory, and
nfs-server waits for every mount rather than exporting what is under it."
```

---

### Task 6: Prod provisioner placeholders

**Files:**
- Modify: `argocd/apps/nfs_provisioner/prod/deployment.yaml:33-41`

**Interfaces:**
- Consumes: server `10.0.0.131`, path `/srv/nfs/prod` (Global Constraints).
- Produces: nothing consumed by later tasks. No Application syncs this directory.

- [ ] **Step 1: Replace the placeholders**

Run: `sed -i 's|value: <server>|value: 10.0.0.131|; s|value: <path>|value: /srv/nfs/prod|; s|server: <server>|server: 10.0.0.131|; s|path: <path>|path: /srv/nfs/prod|' argocd/apps/nfs_provisioner/prod/deployment.yaml && grep -n -E "<server>|<path>|10.0.0.131|/srv/nfs/prod" argocd/apps/nfs_provisioner/prod/deployment.yaml`

Expected: four lines with the real values, none with `<server>` or `<path>`.

- [ ] **Step 2: Render it**

Run: `kustomize build argocd/apps/nfs_provisioner/prod | grep -n -E "server:|path:|value:"` then `scripts/check-manifests.sh`

Expected: the rendered Deployment shows `10.0.0.131` and `/srv/nfs/prod`; `check-manifests.sh` exits 0.

- [ ] **Step 3: Commit**

```bash
git add argocd/apps/nfs_provisioner/prod/deployment.yaml
git commit -m "chore: point prod provisioner at nfs-prod share" -m "Prod scaffolding, never applied: no root-prod Application syncs it."
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/rebuild.md` (table in section 4, section 5, Rebuild order steps 4-5)
- Modify: `CLAUDE.md` (Stack paragraph, Layout, "how a change reaches the cluster" table, load-bearing list, `*.tfvars` bullet)
- Modify: `proxmox/README.md` (tree, modules list, apply commands)
- Modify: `ansible/README.md:164-172`

**Interfaces:**
- Consumes: names from Tasks 1-5: `proxmox/environments/shared`, `shared.tfvars`, `modules/nfs-server`, `inventories/shared`, labels `nfs-dev`/`nfs-prod`, the mount guard.

Locate each anchor with `grep -n` first; the line numbers below are from 2026-09-22 and may have drifted.

- [ ] **Step 1: `docs/rebuild.md` — files table (section 4)**

After the `proxmox/environments/dev/dev.tfvars` row, add:

```markdown
| `proxmox/environments/shared/shared.tfvars`  | Proxmox API token, cloud-init password, `nfs-01`'s IP                | Recreate from `shared.tfvars.example`; every value is also in `dev.tfvars`                                               |
```

After the `proxmox/environments/dev/terraform.tfstate` row, add:

```markdown
| `proxmox/environments/shared/terraform.tfstate` | Local backend for `nfs-01`                                        | See below                                                                                                                |
```

Then run `pre-commit run --files docs/rebuild.md` — if a markdown table formatter hook realigns the columns, accept its output.

- [ ] **Step 2: `docs/rebuild.md` — section 5**

Replace the code block in "### 5. Terraform state after a disk replacement" with:

```bash
for env in shared dev; do
  cd proxmox/environments/$env
  rm terraform.tfstate terraform.tfstate.backup
  terraform init
  terraform apply -var-file=$env.tfvars    # creates everything fresh
  cd -
done
```

and change "The state file lists VMs" to "Each state file lists VMs".

- [ ] **Step 3: `docs/rebuild.md` — Rebuild order**

Replace step 4:

```markdown
4. **`terraform apply -var-file=dev.tfvars`** — six VMs plus the `vault-01`
   LXC container (module `proxmox/modules/lxc`, pool `LXC`).
```

with:

```markdown
4. **`terraform apply`, `shared` first, then `dev`** —
   `proxmox/environments/shared` with `-var-file=shared.tfvars` creates
   `nfs-01` (vmid 103) with its OS disk and the `nfs-dev` and `nfs-prod`
   data disks; `proxmox/environments/dev` with `-var-file=dev.tfvars`
   creates the other five VMs plus the `vault-01` LXC container (module
   `proxmox/modules/lxc`, pool `LXC`).
```

Replace the start of step 5:

```markdown
5. **`ansible-playbook playbooks/nfs_server.yaml`** then `nfs_setup.yaml` —
```

with:

```markdown
5. **`ansible-playbook -i inventories/shared playbooks/nfs_server.yaml`**
   then `nfs_setup.yaml` (default dev inventory) — the first formats and
   mounts both data disks and exports `nfs-dev` to the dev nodes;
```

and keep the rest of step 5's sentence ("storage first, because everything else claims PVCs from it.") after it.

Check the "six VMs" count: run `grep -c '^module' proxmox/environments/dev/main.tf` and list the modules; if the number of VM modules (excluding `vault`) is not five, correct the sentence to the real count.

- [ ] **Step 4: `CLAUDE.md`**

a. Stack paragraph — replace:

```markdown
Only the `dev` environment exists. `proxmox/environments/prod` and `talos/`
are scaffolding that has never been applied — do not extend them without
saying so.
```

with:

```markdown
Only the `dev` environment exists, plus `proxmox/environments/shared` for
`nfs-01`, which serves both environments. `proxmox/environments/prod` and
`talos/` are scaffolding that has never been applied — do not extend them
without saying so.
```

b. Layout block — replace:

```txt
proxmox/          modules/    reusable ubuntu-vm, ubuntu-k8s, lxc, talos-*
                  environments/dev/  the machines that exist
```

with:

```txt
proxmox/          modules/    reusable ubuntu-vm, ubuntu-k8s, lxc,
                              nfs-server, talos-*
                  environments/dev/     the dev machines
                  environments/shared/  nfs-01, serving dev and prod
```

c. "How a change reaches the cluster" table — replace the first row:

```markdown
| VMs, disks, network | `terraform apply -var-file=dev.tfvars` | immediately |
```

with:

```markdown
| VMs, disks, network | `terraform apply -var-file=<env>.tfvars` in `environments/dev` or `environments/shared` | immediately |
```

d. Load-bearing list — after the `nfs-dev` default StorageClass bullet, add:

```markdown
- **The `nfs-dev` share's path is `/srv/nfs/k8s`, not `/srv/nfs/dev`.**
  Every dev PV has `nfs.path: /srv/nfs/k8s/...` baked in, the field is
  immutable, and `nfs-dev` deletes a volume's data when its PVC is deleted.
  Each share is its own disk on `nfs-01` (`scsi1` dev, `scsi2` prod),
  mounted by label; the `nfs_server` role refuses to mount over a
  non-empty directory, and `nfs-server` will not start until both disks
  are mounted. `nfs-prod` has no export line until prod has nodes — an
  export with no client list is exported to everyone.
```

e. `*.tfvars` bullet — replace:

```markdown
- **`*.tfvars` is gitignored and has no backup anywhere.** `dev.tfvars`
  carries the Proxmox API token and the cloud-init password.
```

with:

```markdown
- **`*.tfvars` is gitignored and has no backup anywhere.** `dev.tfvars`
  and `shared.tfvars` carry the Proxmox API token and the cloud-init
  password.
```

- [ ] **Step 5: `proxmox/README.md`**

a. In the tree, after the `dev/` block and before `prod/`, add:

```txt
│   ├── shared/
│   │   ├── .terraform.lock.hcl
│   │   ├── backend.tf.example
│   │   ├── main.tf              # nfs-01, serves nfs-dev and nfs-prod
│   │   ├── outputs.tf
│   │   ├── shared.tfvars.example
│   │   ├── variables.tf
│   │   └── versions.tf
```

and under `modules/`, in alphabetical order, add an `nfs-server/` entry with `main.tf`, `outputs.tf`, `variables.tf`, `versions.tf` in the same style as its neighbours.

b. In the modules list (near the `modules/lxc` bullet), add:

```markdown
- **modules/nfs-server** – `ubuntu-vm` plus two data disks (`scsi1` for `nfs-dev`, `scsi2` for `nfs-prod`); backs `nfs-01` (vmid 103) in `environments/shared`.
```

c. Next to the dev `terraform plan`/`apply` block, add a shared block in the same style:

````markdown
```bash
cd proxmox/environments/shared
terraform plan  -var-file="shared.tfvars"
terraform apply -var-file="shared.tfvars"
```
````

d. Where the README tells you to copy `dev.tfvars.example` and `backend.tf.example`, add the same two `cp` lines for `shared`.

- [ ] **Step 6: `ansible/README.md`**

Replace:

```markdown
   Terraform creates the VM (`proxmox/environments/dev`, module `nfs`);
   these playbooks export the share and install `nfs-common` on the nodes.
```

with:

```markdown
   Terraform creates the VM (`proxmox/environments/shared`, module `nfs`);
   these playbooks format, mount and export its `nfs-dev` and `nfs-prod`
   disks and install `nfs-common` on the nodes. `nfs-01` is in
   `inventories/shared`, not the default dev inventory.
```

and replace:

```bash
ansible-playbook playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
```

with:

```bash
ansible-playbook -i inventories/shared playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
```

Also check lines 50-66 (`grep -n -A3 "nfs-01" ansible/README.md`): if they show a dev inventory example containing `nfs-01`, move it to a shared-inventory example.

- [ ] **Step 7: Check nothing still says NFS lives in dev**

Run: `grep -rn -E "environments/dev.*(nfs|module .nfs.)|nfs.*environments/dev|nfs_vm_ip" --include=*.md . | grep -v docs/superpowers/`

Expected: no hits except ones that are still true. Fix any that are not.

- [ ] **Step 8: Run pre-commit**

Run: `pre-commit run --all-files`

Expected: all hooks Passed.

- [ ] **Step 9: Commit**

```bash
git add docs/rebuild.md CLAUDE.md proxmox/README.md ansible/README.md
git commit -m "docs: describe the shared nfs server" -m "Rebuild order applies shared before dev; the nfs-dev path and mount
guard are recorded as load-bearing."
```

---

### Task 8: Review, push, open the PR

**Files:** none changed; creates the PR body in the scratchpad.

- [ ] **Step 1: Full verification**

Run, from the repo root:

```bash
for d in proxmox/environments/dev proxmox/environments/shared proxmox/modules/nfs-server; do
  (cd $d && terraform init -backend=false -input=false >/dev/null && terraform validate) || echo "FAIL $d"
done
rm -rf proxmox/modules/nfs-server/.terraform proxmox/modules/nfs-server/.terraform.lock.hcl proxmox/environments/shared/.terraform
terraform fmt -recursive -check proxmox
pre-commit run --all-files
scripts/check-manifests.sh
git status --short
```

Expected: three `Success!`, no `FAIL`, no fmt output, all hooks Passed, check-manifests exits 0, clean working tree.

- [ ] **Step 2: Code review** — invoke `superpowers:requesting-code-review` against the branch diff from `main`. Fix findings on the branch.

- [ ] **Step 3: Pre-merge checks** — invoke `superpowers:finishing-a-development-branch` for its checks. Stop before it merges: choose "push and open a PR".

- [ ] **Step 4: Write the PR body** to `$SCRATCH/pr-body.md`:

```markdown
Moves `nfs-01` (vmid 103) out of the dev environment into
`proxmox/environments/shared` and `ansible/inventories/shared`, and splits
its one export into two shares on their own disks:

| Share | Disk | Path | Clients |
| --- | --- | --- | --- |
| nfs-dev | scsi1, 50G | `/srv/nfs/k8s` | master-01, worker-01, worker-02 |
| nfs-prod | scsi2, 50G | `/srv/nfs/prod` | none yet, so no export line |

The dev path stays `/srv/nfs/k8s` because existing PVs have it baked in.
Nothing on the cluster side changes; the only manifest change is the prod
provisioner, which nothing syncs.

Spec: `docs/superpowers/specs/2026-09-22-nfs-shared-server-design.md`
Plan: `docs/superpowers/plans/2026-09-22-nfs-shared-server.md`

## Operator steps — before merging, in order

All manual; none waits on the merge. Full commands are in the plan's
Task 9.

1. Pre-flight: `pvesm status` — `local-lvm` is `lvmthin` with 100G+ free.
2. dev: `terraform plan` shows exactly one resource *removed from state*,
   0 to add/change/destroy. Apply.
3. shared: create `shared.tfvars`; `terraform plan` shows 1 import,
   in-place updates only (scsi1/scsi2, tags), **0 to destroy, no
   replacement**. Apply.
4. Migrate `/srv/nfs/k8s` onto the new dev disk with the dev stateful apps
   scaled down.
5. Run `nfs_server.yaml -i inventories/shared`; verify, reboot `nfs-01`,
   verify again.
6. Push the follow-up commit that drops the `import` and `removed` blocks.

## Checks

- `terraform validate` / `fmt` / `tflint` on dev, shared, nfs-server module
- `ansible-lint` (production), `--syntax-check` on the shared inventory
- `pre-commit run --all-files`, `scripts/check-manifests.sh`
```

- [ ] **Step 5: Push and open**

```bash
git push -u origin nfs-shared-server
gh pr create --base main --head nfs-shared-server --title "feat: move nfs-01 to shared with dev and prod shares" --body-file $SCRATCH/pr-body.md
```

If `gh` returns 403, run `gh auth status` and check for a `GH_TOKEN`/`GITHUB_TOKEN` override before anything else. Report the PR URL. Do not merge.

---

### Task 9: Operator steps (repository owner runs these)

Not for agents. The supervisor hands these to the owner and records results as they are reported. Run from the branch checkout, in order. **Any unexpected output: stop and report before the next step.**

- [ ] **Step 1: Pre-flight on the Proxmox host**

```bash
pvesm status
```

Expected: `local-lvm` has type `lvmthin` and at least 100G available. If it is plain `lvm` or has less room, stop — the disk sizes need revisiting.

- [ ] **Step 2: dev plan and apply**

Delete the `nfs_vm_ip` line from your real `dev.tfvars`, then:

```bash
cd proxmox/environments/dev
terraform plan -var-file=dev.tfvars
```

Expected: `module.nfs.proxmox_vm_qemu.ubuntu_vm will no longer be managed by Terraform` and `Plan: 0 to add, 0 to change, 0 to destroy.` Nothing else. Then:

```bash
terraform apply -var-file=dev.tfvars
qm status 103   # on the host: still running
```

- [ ] **Step 3: shared plan and apply**

```bash
cd ../shared
cp backend.tf.example backend.tf
cp shared.tfvars.example shared.tfvars   # then copy the real values from dev.tfvars
terraform init
terraform plan -var-file=shared.tfvars
```

Expected: `module.nfs.proxmox_vm_qemu.nfs_server will be imported`, an in-place update (`~`) adding `scsi1` and `scsi2` and changing `tags`, and `Plan: 1 to import, 0 to add, 1 to change, 0 to destroy.` **If the plan says `must be replaced` or `to destroy` is not 0, stop.** Paste the plan; the module is fixed on the branch until the plan is a pure update. Other in-place attribute changes (e.g. `cipassword`) are fine if the values are yours.

```bash
terraform apply -var-file=shared.tfvars
```

On the host: `qm config 103 | grep -E '^scsi[0-2]'` shows three disks. On `nfs-01`: `ls -l /dev/disk/by-id/ | grep drive-scsi` shows `...drive-scsi1` and `...drive-scsi2`. If the names differ, stop: the role's `device` paths need changing.

- [ ] **Step 4: Stop the dev stateful apps**

From a machine with `kubectl` access to dev:

```bash
# root-dev's selfHeal would re-enable the children's auto-sync, so it goes first
kubectl -n argocd patch application root-dev --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
for app in nfs gitea harbor monitoring jobboard; do
  kubectl -n argocd patch application $app --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

NS="$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u) nfs-system"
for ns in $NS; do
  kubectl -n $ns get deploy,sts -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.replicas}{"\n"}{end}' | sed "s|^|$ns |"
done > ~/nfs-migration-replicas.txt
cat ~/nfs-migration-replicas.txt
for ns in $NS; do kubectl -n $ns scale deploy,sts --all --replicas=0; done
kubectl get pods -A | grep -E "$(echo $NS | tr ' ' '|')"
```

Expected: `nfs-migration-replicas.txt` lists every workload with its replica count; after the scale, no pods left in those namespaces (wait until terminating ones finish).

- [ ] **Step 5: Copy the data onto the dev disk (on `nfs-01`)**

```bash
DEV=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
sudo mkfs.ext4 -L nfs-dev $DEV
sudo mkdir -p /mnt/nfs-dev && sudo mount LABEL=nfs-dev /mnt/nfs-dev
sudo rsync -aHAX --numeric-ids /srv/nfs/k8s/ /mnt/nfs-dev/
sudo find /srv/nfs/k8s | wc -l; sudo find /mnt/nfs-dev | wc -l   # equal, except lost+found adds 1
sudo du -s --apparent-size /srv/nfs/k8s /mnt/nfs-dev              # within a few MB
sudo umount /mnt/nfs-dev
sudo systemctl stop nfs-server
sudo mv /srv/nfs/k8s /srv/nfs/k8s.old
sudo mkdir /srv/nfs/k8s
```

- [ ] **Step 6: Run the role**

```bash
cd ansible
ansible-playbook -i inventories/shared playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
```

Expected: the guard passes, `Create each share's filesystem` leaves `nfs-dev` alone and formats `nfs-prod`, both mounts `changed`, and `Show the published exports` lists `/srv/nfs/k8s` with the three dev node IPs and nothing for prod.

- [ ] **Step 7: Verify on `nfs-01`**

```bash
findmnt /srv/nfs/k8s /srv/nfs/prod        # LABEL=nfs-dev and LABEL=nfs-prod
cat /etc/exports                           # one export line
showmount -e localhost
ls /srv/nfs/k8s | head                      # the PV directories
sudo reboot
# after it is back:
findmnt /srv/nfs/k8s /srv/nfs/prod && showmount -e localhost
systemctl show nfs-server -p RequiresMountsFor
```

- [ ] **Step 8: Bring the apps back**

```bash
while read ns obj n; do kubectl -n $ns scale $obj --replicas=$n; done < ~/nfs-migration-replicas.txt
kubectl apply -f argocd/environments/dev/applications/app-of-apps.yaml   # restores root-dev auto-sync
kubectl -n argocd get applications     # root-dev re-syncs the children, restoring their auto-sync
kubectl get pvc -A                      # all Bound
kubectl get pods -A | grep -v -E 'Running|Completed'
```

Then check the things themselves: the gitea UI loads with its repos, a `docker push` to Harbor succeeds, `kubectl -n jobboard exec sts/postgres -- psql -U postgres -c 'select 1'` answers, Grafana shows historic data.

- [ ] **Step 9: A new PVC lands on the new disk**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: nfs-probe, namespace: default}
spec: {accessModes: [ReadWriteMany], resources: {requests: {storage: 1Mi}}}
EOF
kubectl get pvc nfs-probe -n default    # Bound
# on nfs-01:
ls -d /srv/nfs/k8s/default-nfs-probe-* && df /srv/nfs/k8s | tail -1   # on the nfs-dev disk
kubectl delete pvc nfs-probe -n default
```

- [ ] **Step 10: Report back** — tell the supervisor each step's result. Keep `/srv/nfs/k8s.old` for a week, then `sudo rm -rf /srv/nfs/k8s.old`.

---

### Task 10: Drop the one-shot `import` and `removed` blocks

Run only after Task 9 Steps 2 and 3 are reported applied.

**Files:**
- Modify: `proxmox/environments/shared/main.tf` (the `import` block and its comment)
- Modify: `proxmox/environments/dev/main.tf` (the `removed` block and its comment)

**Interfaces:**
- Consumes: Task 9's confirmation that both applies succeeded.

- [ ] **Step 1: Delete the blocks**

In `shared/main.tf`, delete the `# Adopts the existing nfs-01 ...` comment and the `import { ... }` block. In `dev/main.tf`, replace the `NFS Server -- moved to environments/shared` banner, its comment and the `removed { ... }` block with a single comment line:

```hcl
# nfs-01 (vmid 103) lives in proxmox/environments/shared.
```

- [ ] **Step 2: Validate both roots**

Run: `for env in dev shared; do (cd proxmox/environments/$env && terraform init -backend=false -input=false >/dev/null && terraform validate && tflint --config=/home/ubuntu/homelab/.tflint.hcl); done; rm -rf proxmox/environments/shared/.terraform; terraform fmt -recursive -check proxmox`

Expected: two `Success!`, no tflint or fmt output.

- [ ] **Step 3: Ask the owner to confirm both plans are empty**

Owner runs `terraform plan -var-file=<env>.tfvars` in `dev` and `shared`. Expected: `No changes.` in both.

- [ ] **Step 4: Commit and push**

```bash
git add proxmox/environments/dev/main.tf proxmox/environments/shared/main.tf
git commit -m "chore: drop one-shot nfs import and removed blocks" -m "Both applies have run. On a rebuilt host vmid 103 does not exist, and
an import block for it would fail the shared plan."
git push
```
