# Talos Prod Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unusable prod scaffolding with a Talos cluster (one control plane, two workers) that one `terraform apply` brings to three Ready nodes.

**Architecture:** A new `modules/talos-node` clones the `talos-tp` template with a static cloud-init address. The prod root calls it with `for_each` over one `talos_nodes` map and drives the `siderolabs/talos` provider (secrets, machine configs, apply, bootstrap, kubeconfig). Secrets live only in `terraform.tfstate`.

**Tech Stack:** Terraform `~> 1.16.0`, `telmate/proxmox` `3.0.2-rc10`, `siderolabs/talos` `0.12.0`, Talos `v1.14.2`, GitHub Actions CI.

**Spec:** `docs/superpowers/specs/2026-10-01-talos-prod-design.md` (read it first; this plan implements it).

## Global Constraints

- Work only in the worktree `/home/ubuntu/homelab/.worktrees/talos-prod` on branch `talos-prod`. Never switch branches in `/home/ubuntu/homelab` and never use bare `git stash`.
- No `terraform apply`, no `terraform plan` against Proxmox: this session has no tfvars, state or kubeconfig. Verification is `fmt`, `init -backend=false`, `validate`, `terraform test` (mock providers) and `tflint`.
- Terraform `~> 1.16.0`; `telmate/proxmox` exactly `3.0.2-rc10`; `siderolabs/talos` exactly `0.12.0`.
- Talos version `v1.14.2`. Image Factory schematic `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515` (`nocloud` image, extension `siderolabs/qemu-guest-agent`).
- Template `talos-tp`, pool `Talos-K8s`. Nodes: `cp1` (vmid 3101, `10.0.0.110`), `w1` (3201, `10.0.0.111`), `w2` (3202, `10.0.0.112`), 2048 MiB each. These live in the gitignored `prod.tfvars`; the committed `.example` carries placeholders from the same block.
- `kubeconfig` and `talosconfig` are `sensitive` outputs. Nothing writes them to disk: no `local_file`, no `terraform output` redirect inside any committed script.
- The only secret-bearing files are `terraform.tfstate` and `prod.tfvars`; both are already gitignored. Verify with `git check-ignore -v`, never assume.
- Commits: Conventional Commits, subject at most 50 characters, imperative, lowercase, no trailing period, body wrapped at 72. Types `feat fix refactor docs chore ops ci`. **No `Co-Authored-By` trailer and no generated-with footer.** Never `--no-verify`; fix what a pre-commit hook reports.
- Prose in committed docs: say "the operator's workstation", never "the Mac" or "the laptop". Do not mention the original author, the original repository, or the old `talos/_out` leak.
- A Terraform rename after the first apply needs a `moved` block (ADR 0013). Prod has never been applied, so none are needed in this PR.
- Do not touch `docs/superpowers/plans/2026-09-28-lan-services-apps.md` (the Glance branch edits it).
- The ADR number is 0021 (0020 is taken on the Glance branch).

## Review Focus

1. **Two or zero control planes in `talos_nodes`:** the variable's validation rejects it with a clear message (Task 4 test `rejects_two_controlplanes`, `rejects_no_controlplane`).
2. **Duplicate IP or vmid across nodes:** rejected, since a duplicate IP silently splits a cluster (Task 4 tests `rejects_duplicate_ip`, `rejects_duplicate_vmid`).
3. **A node under 2048 MiB:** rejected, since Talos's documented minimum is 2G (Task 4 test `rejects_small_memory`).
4. **A secret reaching the working tree:** after `init`, `validate` and `test`, `git status --porcelain` lists no `*.kubeconfig`, `talosconfig`, `*.tfstate` or `*.tfvars` (Task 4 step 12 and Task 7).
5. **A bad IP string (`10.0.0.300`, a hostname, a CIDR):** rejected at validation rather than failing mid-apply (Task 4 test `rejects_bad_ip`).

---

## File Structure

| Path | Action | Responsibility |
| --- | --- | --- |
| `CLAUDE.md` | modify | drop the "do not extend" rule (Task 1); describe prod as real (Task 6) |
| `terraform/modules/talos-k8s/` | delete | old module (Task 2) |
| `terraform/modules/talos-vm/` | delete | old module (Task 2) |
| `talos/` | delete | old README and patch templates (Task 2) |
| `terraform/environments/prod/{main,outputs,variables,versions}.tf`, `prod.tfvars.example` | replace | the new root (Tasks 2 and 4) |
| `terraform/modules/talos-node/{versions,variables,main,outputs}.tf` | create | one Talos VM: full clone of `talos-tp`, static cloud-init address (Task 3) |
| `terraform/environments/prod/talos.tf` | create | machine secrets, configs, apply, bootstrap, kubeconfig (Task 4) |
| `terraform/environments/prod/prod.tftest.hcl` | create | mock-provider tests for the node map (Task 4) |
| `terraform/environments/prod/.terraform.lock.hcl` | regenerate | new provider pins (Task 4) |
| `.github/workflows/ci.yaml` | modify | add `prod` to both Terraform loops (Task 5) |
| `docs/rebuild.md`, `README.md`, `terraform/README.md`, `CLAUDE.md`, `docs/decisions/0021-*.md`, `docs/decisions/README.md`, `docs/decisions/0012-*.md` | modify/create | documentation (Task 6) |

The worktree already contains the spec (committed) and this plan.

---

### Task 1: Remove the scaffolding rule from CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (the Stack paragraph, around lines 25-30)

**Interfaces:**
- Consumes: nothing.
- Produces: a CLAUDE.md that no longer forbids extending prod.

- [ ] **Step 1: Find the sentence**

Run: `grep -n "scaffolding that has never been" CLAUDE.md`
Expected: one hit in the Stack paragraph.

- [ ] **Step 2: Delete the rule**

In the Stack paragraph, delete exactly these lines (they currently read `` `terraform/environments/prod` and `talos/` are scaffolding that has never been `` / `applied — do not extend them without saying so.`), and leave the preceding sentence about the prod halves of `nfs-prod` and `kv-prod` intact. If the sentence before now ends mid-thought, end it with a period. Do nothing else in this task; Task 6 rewrites the rest of the paragraph.

- [ ] **Step 3: Verify**

Run: `grep -n "do not extend" CLAUDE.md; echo "exit=$?"`
Expected: no match, `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: drop the do-not-extend-prod rule" -m "The rule guarded unusable scaffolding. Real prod work starts in this
branch, so it no longer applies."
```

---

### Task 2: Delete the old Talos scaffolding

**Files:**
- Delete: `terraform/modules/talos-k8s/`, `terraform/modules/talos-vm/`, `talos/`
- Delete: `terraform/environments/prod/main.tf`, `outputs.tf`, `variables.tf`, `prod.tfvars.example`
- Keep: `terraform/environments/prod/backend.tf.example`, `versions.tf` (rewritten in Task 4), `.terraform.lock.hcl` (regenerated in Task 4)

**Interfaces:**
- Consumes: nothing.
- Produces: a prod root with only `backend.tf.example`, `versions.tf`, the lock file; Task 4 fills it.

- [ ] **Step 1: Delete**

```bash
git rm -r -q terraform/modules/talos-k8s terraform/modules/talos-vm talos
git rm -q terraform/environments/prod/main.tf terraform/environments/prod/outputs.tf \
  terraform/environments/prod/variables.tf terraform/environments/prod/prod.tfvars.example
```

- [ ] **Step 2: Verify nothing else imports them**

Run: `grep -rIn "modules/talos-k8s\|modules/talos-vm\|talos-tp" --exclude-dir=.git . | grep -v "^./docs/superpowers"`
Expected: hits only in `README.md`, `terraform/README.md` and `docs/rebuild.md` (prose that Task 6 rewrites), none in `.tf` files.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: delete the old talos scaffolding" -m "modules/talos-k8s, modules/talos-vm, talos/ and the prod root's
main, outputs, variables and tfvars example. The prod root is rebuilt
from scratch in the commits that follow."
```

---

### Task 3: The `talos-node` module

**Files:**
- Create: `terraform/modules/talos-node/versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

**Interfaces:**
- Consumes: nothing.
- Produces: `module "talos-node"` with these inputs and outputs, used by Task 4:
  - Inputs: `vm_name string`, `target_node string`, `vmid number`, `pool string`, `clone_template string`, `memory number`, `cpu_cores number`, `disk_size string`, `disk_storage string`, `cloudinit_storage string`, `network_bridge string`, `network_firewall bool`, `ip string` (bare address, no CIDR), `prefix_length number`, `gateway string`, `nameserver string`, `start_at_node_boot bool`, `tags string`
  - Outputs: `vm_id` (number), `vm_name` (string), `ip` (string)

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
variable "vm_name" {
  description = "VM name, also the node's hostname (Proxmox cloud-init passes it to Talos)"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to deploy on"
  type        = string
}

variable "vmid" {
  description = "VM ID (must be unique on the host)"
  type        = number
}

variable "pool" {
  description = "Resource pool; terraform@pve needs TerraformProv on it"
  type        = string
}

variable "clone_template" {
  description = "Template to full-clone (the Talos nocloud image)"
  type        = string
}

variable "memory" {
  description = "Memory in MiB. Talos's documented minimum is 2048"
  type        = number
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "disk_size" {
  description = "Boot disk size; the Talos image grows its EPHEMERAL partition to fill it"
  type        = string
  default     = "20G"
}

variable "disk_storage" {
  description = "Storage for the boot disk"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_storage" {
  description = "Storage for the cloud-init drive"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Bridge the node attaches to"
  type        = string
  default     = "vmbr0"
}

variable "network_firewall" {
  description = "Enable the Proxmox firewall on the interface"
  type        = bool
  default     = false
}

variable "ip" {
  description = "Static IPv4 address, without a prefix length"
  type        = string
}

variable "prefix_length" {
  description = "Prefix length of the LAN, e.g. 24"
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "nameserver" {
  description = "DNS server handed to Talos through cloud-init"
  type        = string
  default     = "1.1.1.1"
}

variable "start_at_node_boot" {
  description = "Start the VM when the Proxmox host boots"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Proxmox tags"
  type        = string
  default     = "talos,prod"
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
# One Talos node: a full clone of the talos-tp template (the Image Factory
# nocloud image with qemu-guest-agent). Proxmox's cloud-init drive carries the
# static address; Talos's nocloud platform reads it at first boot, so the node
# comes up in maintenance mode on its planned address and the talos provider
# can apply a machine config to it. There is no SSH and no cloud-init user.
resource "proxmox_vm_qemu" "node" {
  name        = var.vm_name
  target_node = var.target_node
  vmid        = var.vmid
  pool        = var.pool
  power_state = "running"

  # A resize needs a restart. Left pending, the operator restarts nodes one
  # at a time; automatic reboots would take all three down together.
  automatic_reboot = false

  lifecycle {
    ignore_changes = [
      power_state,
      clone,
      full_clone,
    ]
  }

  clone      = var.clone_template
  full_clone = true

  memory = var.memory
  cpu {
    cores   = var.cpu_cores
    limit   = 0
    numa    = false
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  machine = "q35"
  qemu_os = "l26"
  scsihw  = "virtio-scsi-single"

  boot               = "order=scsi0"
  start_at_node_boot = var.start_at_node_boot

  # The guest agent comes from the image's extension list. In maintenance
  # mode it may not answer yet, so the provider must not wait on it for an
  # SSH address: Talos has no SSH.
  agent                  = 1
  define_connection_info = false
  clone_wait             = 10
  additional_wait        = 5
  skip_ipv6              = true

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
    }
    ide {
      ide2 {
        cloudinit {
          storage = var.cloudinit_storage
        }
      }
    }
  }

  network {
    id        = 0
    model     = "virtio"
    bridge    = var.network_bridge
    firewall  = var.network_firewall
    link_down = false
  }

  serial {
    id   = 0
    type = "socket"
  }

  ipconfig0  = "ip=${var.ip}/${var.prefix_length},gw=${var.gateway}"
  nameserver = var.nameserver

  tags = var.tags
}
```

- [ ] **Step 4: Write `outputs.tf`**

```hcl
output "vm_id" {
  description = "The VM's Proxmox ID"
  value       = proxmox_vm_qemu.node.vmid
}

output "vm_name" {
  description = "The VM's name"
  value       = proxmox_vm_qemu.node.name
}

output "ip" {
  description = "The static address this node is configured with"
  value       = var.ip
}
```

- [ ] **Step 5: Validate the module**

```bash
terraform -chdir=terraform/modules/talos-node fmt -check
terraform -chdir=terraform/modules/talos-node init -backend=false -input=false
terraform -chdir=terraform/modules/talos-node validate
tflint --chdir=terraform/modules/talos-node --config="$PWD/.tflint.hcl"
```
Expected: `fmt` prints nothing, `validate` prints `Success! The configuration is valid.`, `tflint` exits 0. If `validate` rejects an argument (`automatic_reboot`, `skip_ipv6`, `nameserver`, `define_connection_info`), check it against `terraform/modules/vault-vm/main.tf` or `ubuntu-vm`, which use the same provider version, and fix the module — do not delete the argument without saying why in your report.

- [ ] **Step 6: Remove the untracked init artefacts and commit**

```bash
git status --porcelain terraform/modules/talos-node
```
Expected: only the four `.tf` files (`.terraform/` is gitignored; the module's `.terraform.lock.hcl` must NOT be committed — delete it: `rm -f terraform/modules/talos-node/.terraform.lock.hcl`, matching the other modules, which carry none).

```bash
git add terraform/modules/talos-node
git commit -m "feat: add the talos-node module" -m "One Talos VM: a full clone of talos-tp with a static cloud-init
address, no SSH, restarts left to the operator."
```

---

### Task 4: The prod root, tests first

**Files:**
- Create: `terraform/environments/prod/variables.tf`, `versions.tf` (replace), `main.tf`, `talos.tf`, `outputs.tf`, `prod.tfvars.example`, `prod.tftest.hcl`
- Regenerate: `terraform/environments/prod/.terraform.lock.hcl`

**Interfaces:**
- Consumes: `modules/talos-node` (Task 3) with the inputs listed there.
- Produces: root outputs `kubeconfig` (sensitive), `talosconfig` (sensitive), `node_ips` (map name→ip), `controlplane_ip`; variables listed in Step 3.

- [ ] **Step 1: Write `versions.tf`**

```hcl
terraform {
  required_version = "~> 1.16.0"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc10"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
}

provider "talos" {}
```

- [ ] **Step 2: Write the failing tests, `prod.tftest.hcl`**

```hcl
# Mock providers: nothing here reaches Proxmox or a Talos node. These tests
# pin the rules the node map must obey.
mock_provider "proxmox" {}
mock_provider "talos" {}

variables {
  pm_api_url          = "https://pve.invalid:8006/api2/json"
  pm_api_token_id     = "terraform@pve!test"
  pm_api_token_secret = "not-a-secret"
  pm_target_node      = "pve"
  gateway             = "10.0.0.1"
  talos_nodes = {
    cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
    w1  = { role = "worker", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
    w2  = { role = "worker", vmid = 3202, ip = "10.0.0.112", memory = 2048 }
  }
}

run "three_nodes_one_controlplane" {
  command = plan

  assert {
    condition     = length(output.node_ips) == 3
    error_message = "expected three nodes"
  }
  assert {
    condition     = output.controlplane_ip == "10.0.0.110"
    error_message = "the control plane address must be cp1's"
  }
}

run "rejects_two_controlplanes" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      cp2 = { role = "controlplane", vmid = 3102, ip = "10.0.0.111", memory = 2048 }
      w1  = { role = "worker", vmid = 3201, ip = "10.0.0.112", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_no_controlplane" {
  command = plan
  variables {
    talos_nodes = {
      w1 = { role = "worker", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
      w2 = { role = "worker", vmid = 3202, ip = "10.0.0.112", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_duplicate_ip" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      w1  = { role = "worker", vmid = 3201, ip = "10.0.0.110", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_duplicate_vmid" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      w1  = { role = "worker", vmid = 3101, ip = "10.0.0.111", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_small_memory" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 1024 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_bad_ip" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.300", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_unknown_role" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      w1  = { role = "master", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}
```

- [ ] **Step 3: Write `variables.tf` with only the plain variables first, then confirm the tests fail**

Write the file with everything below **except** the `validation` blocks in `talos_nodes` (add them in Step 5):

```hcl
# Proxmox
variable "pm_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API token ID"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "pm_target_node" {
  description = "Proxmox node the VMs run on"
  type        = string
}

# Network
variable "gateway" {
  description = "Default gateway for the static addresses"
  type        = string
}

variable "prefix_length" {
  description = "Prefix length of the LAN"
  type        = number
  default     = 24
}

variable "nameserver" {
  description = "DNS server handed to the nodes through cloud-init"
  type        = string
  default     = "1.1.1.1"
}

# Cluster
variable "cluster_name" {
  description = "Talos / Kubernetes cluster name; prefixes every VM name"
  type        = string
  default     = "talos-prod"
}

variable "clone_template" {
  description = "Template every node full-clones: the Image Factory nocloud image"
  type        = string
  default     = "talos-tp"
}

variable "pool" {
  description = "Resource pool for the nodes; created by hand, see docs/rebuild.md"
  type        = string
  default     = "Talos-K8s"
}

variable "talos_version" {
  description = "Talos release. Must match the image baked into the template"
  type        = string
  default     = "v1.14.2"
}

variable "talos_schematic_id" {
  description = "Image Factory schematic: nocloud with the qemu-guest-agent extension. Keeps the extension across upgrades"
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

variable "kubernetes_version" {
  description = "Kubernetes version baked into the machine configs; null takes the provider's default for talos_version"
  type        = string
  default     = null
}

variable "node_cores" {
  description = "CPU cores per node"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Boot disk size per node"
  type        = string
  default     = "20G"
}

variable "talos_nodes" {
  description = "Nodes by short name (cp1, w1, ...). Exactly one controlplane."
  type = map(object({
    role   = string
    vmid   = number
    ip     = string
    memory = number
  }))
}
```

Run: `cd terraform/environments/prod && terraform init -backend=false -input=false -upgrade >/dev/null` — this fails until `main.tf` exists? No: init only needs `versions.tf`. Expected: success, and `.terraform.lock.hcl` now pins `siderolabs/talos 0.12.0` and `Telmate/proxmox 3.0.2-rc10`.

Now write `main.tf`, `talos.tf` and `outputs.tf` (Steps 4 and 6 below give their content) **before** running `terraform test`, because the tests need a loadable root. Run:

`terraform -chdir=terraform/environments/prod test`
Expected: `three_nodes_one_controlplane` passes; the six `rejects_*` runs FAIL with "expected failure but none occurred" (no validation blocks yet). Record that output.

- [ ] **Step 4: Write `main.tf`**

```hcl
# The Talos prod cluster: one control plane and two workers, cloned from the
# talos-tp template. The node map lives in prod.tfvars.
module "node" {
  source   = "../../modules/talos-node"
  for_each = var.talos_nodes

  vm_name        = "${var.cluster_name}-${each.key}"
  target_node    = var.pm_target_node
  vmid           = each.value.vmid
  pool           = var.pool
  clone_template = var.clone_template

  memory    = each.value.memory
  cpu_cores = var.node_cores
  disk_size = var.node_disk_size

  ip            = each.value.ip
  prefix_length = var.prefix_length
  gateway       = var.gateway
  nameserver    = var.nameserver
}
```

- [ ] **Step 5: Add the validations to `talos_nodes`**

Replace the `talos_nodes` variable with:

```hcl
variable "talos_nodes" {
  description = "Nodes by short name (cp1, w1, ...). Exactly one controlplane."
  type = map(object({
    role   = string
    vmid   = number
    ip     = string
    memory = number
  }))

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : contains(["controlplane", "worker"], n.role)])
    error_message = "role must be \"controlplane\" or \"worker\"."
  }

  validation {
    condition     = length([for n in values(var.talos_nodes) : n if n.role == "controlplane"]) == 1
    error_message = "talos_nodes needs exactly one controlplane: the cluster endpoint is that node's address and there is no VIP."
  }

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : can(cidrhost("${n.ip}/32", 0)) && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", n.ip))])
    error_message = "ip must be a bare IPv4 address such as 10.0.0.110, with no prefix length."
  }

  validation {
    condition     = length(distinct([for n in values(var.talos_nodes) : n.ip])) == length(var.talos_nodes)
    error_message = "Two nodes share an IP address."
  }

  validation {
    condition     = length(distinct([for n in values(var.talos_nodes) : n.vmid])) == length(var.talos_nodes)
    error_message = "Two nodes share a vmid."
  }

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : n.memory >= 2048])
    error_message = "memory must be at least 2048 MiB, Talos's documented minimum."
  }
}
```

- [ ] **Step 6: Write `talos.tf` and `outputs.tf`**

`talos.tf`:

```hcl
locals {
  controlplane_key = one([for k, n in var.talos_nodes : k if n.role == "controlplane"])
  controlplane_ip  = var.talos_nodes[local.controlplane_key].ip

  # No VIP: with one control plane the endpoint is that node.
  cluster_endpoint = "https://${local.controlplane_ip}:6443"

  # The factory installer keeps the qemu-guest-agent extension across
  # upgrades. /dev/sda is scsi0 on virtio-scsi-single.
  install_image = "factory.talos.dev/nocloud-installer/${var.talos_schematic_id}:${var.talos_version}"
}

# The cluster's PKI. It exists only in terraform.tfstate.
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.talos_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/sda"
          image = local.install_image
        }
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.controlplane_ip]
  nodes                = [for n in values(var.talos_nodes) : n.ip]
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.talos_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip

  depends_on = [module.node]
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.controlplane_ip
  endpoint             = local.controlplane_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.node[local.controlplane_key]]
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = local.controlplane_ip
  endpoint             = local.controlplane_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}
```

If `terraform validate` rejects `depends_on` with an indexed resource instance (`talos_machine_configuration_apply.node[local.controlplane_key]`), use `talos_machine_configuration_apply.node` (the whole set) instead and say so in your report.

`outputs.tf`:

```hcl
output "kubeconfig" {
  description = "Cluster kubeconfig. Fetch: terraform output -raw kubeconfig > ~/.kube/talos-prod"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config. Fetch: terraform output -raw talosconfig > ~/.talos/config"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "node_ips" {
  description = "Node name to static address"
  value       = { for k, n in var.talos_nodes : k => n.ip }
}

output "controlplane_ip" {
  description = "The control plane's address, which is the cluster endpoint"
  value       = local.controlplane_ip
}
```

- [ ] **Step 7: Run the tests, expect green**

```bash
terraform -chdir=terraform/environments/prod fmt -check -recursive
terraform -chdir=terraform/environments/prod validate
terraform -chdir=terraform/environments/prod test
```
Expected: `validate` succeeds; `test` reports 8 passed, 0 failed. If a `rejects_*` run fails because the mock provider rejects the shape of a plan before the validation fires, the failing run's diagnostics will say so; fix the root, not the test. If `terraform test` cannot run a mock-provider plan against the `talos` provider's nested `machine_secrets` schema at all, do NOT delete the tests: report the exact error and fall back to `terraform validate` plus a manual check of the validations with `terraform console` using `-var` JSON, and say so.

- [ ] **Step 8: Write `prod.tfvars.example`**

Mirror the header style of `terraform/environments/shared/shared.tfvars.example` (read it first; copy its Proxmox block and token-id format exactly). Content:

```hcl
# Copy to prod.tfvars and fill in. prod.tfvars is gitignored (*.tfvars) and
# has no backup anywhere. It carries the Proxmox API token.
#
# Prerequisites, none of which Terraform creates (docs/rebuild.md):
#   - the Talos-K8s resource pool, with TerraformProv granted on it
#   - the talos-tp template, built from the Image Factory nocloud image

pm_target_node      = "pve"
pm_api_url          = "https://<PROXMOX_IP>:8006/api2/json"
pm_api_token_id     = "<TOKEN_ID>"
pm_api_token_secret = "<UUID>"

# The LAN's gateway. Node addresses sit above the router's DHCP pool
# (.2-.99), in the block the README diagram reserves for Talos.
gateway = "10.0.0.1"

talos_nodes = {
  cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
  w1  = { role = "worker", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
  w2  = { role = "worker", vmid = 3202, ip = "10.0.0.112", memory = 2048 }
}
```

- [ ] **Step 9: Regenerate the lock file for CI and the operator's workstation**

```bash
cd terraform/environments/prod
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
```
Expected: `.terraform.lock.hcl` lists `Telmate/proxmox 3.0.2-rc10` and `siderolabs/talos 0.12.0`, with no `3.0.2-rc04` left. Check: `grep -n 'version' .terraform.lock.hcl`.

- [ ] **Step 10: tflint**

Run: `tflint --chdir=terraform/environments/prod --config="$(git rev-parse --show-toplevel)/.tflint.hcl"`
Expected: exit 0. Fix findings; do not disable rules.

- [ ] **Step 11: Confirm no secret-bearing file appeared**

```bash
git status --porcelain
git check-ignore -v terraform/environments/prod/terraform.tfstate terraform/environments/prod/prod.tfvars
```
Expected: `git status` lists only the files this task created or changed (no `*.tfstate`, `*.tfvars`, kubeconfig or talosconfig); both `check-ignore` lines print a matching rule from `.gitignore`.

- [ ] **Step 12: Commit**

```bash
git add terraform/environments/prod
git commit -m "feat: build the talos prod root" -m "Three nodes from the talos-node module, cluster secrets, configs,
bootstrap and kubeconfig from the siderolabs/talos provider. The node
map is validated: one control plane, unique IPs and vmids, at least 2G.
Pins now match shared, and the lock file is regenerated."
```

---

### Task 5: Add prod to CI

**Files:**
- Modify: `.github/workflows/ci.yaml` (the two `for env in dev shared` loops, around lines 121 and 127)

**Interfaces:**
- Consumes: a prod root that inits with `-backend=false` (Task 4).
- Produces: CI validating and linting prod.

- [ ] **Step 1: Edit both loops**

Change both occurrences of `for env in dev shared; do` to `for env in dev shared prod; do`. Check: `grep -n "for env in" .github/workflows/ci.yaml` shows `dev shared prod` twice and nothing else.

- [ ] **Step 2: Run the same commands CI runs**

```bash
for env in dev shared prod; do
  terraform -chdir=terraform/environments/$env init -backend=false -input=false >/dev/null
  terraform -chdir=terraform/environments/$env validate
  tflint --chdir=terraform/environments/$env --config="$PWD/.tflint.hcl"
done
```
Expected: three `Success! The configuration is valid.` lines and no tflint output. Clean up: `git status --porcelain` shows only `ci.yaml` modified.

- [ ] **Step 3: actionlint, if installed**

Run: `command -v actionlint && actionlint .github/workflows/ci.yaml`
Expected: no output (or the command is absent; skip).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "ci: validate and lint the prod root" -m "prod inits now that its pins match shared and dev."
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/rebuild.md`, `README.md`, `terraform/README.md`, `CLAUDE.md`, `docs/decisions/0012-hub-and-spoke-topology.md`, `docs/decisions/README.md`
- Create: `docs/decisions/0021-talos-prod-via-terraform-provider.md`

**Interfaces:**
- Consumes: everything built in Tasks 2-5.
- Produces: docs that are true about the merged branch.

- [ ] **Step 1: `docs/rebuild.md` — the template and pool**

Read sections 1 and 2 first and mirror their style (heading levels, `bash` fences, how existing pool and ACL commands are written; if section 1 already uses `pveum` for pools, use the same form). Replace the three-line `talos-tp` note near line 205 ("The `talos-tp` template hard-coded at … ignored unless that changes.") with this subsection:

````markdown
### 2b. The Talos pool and template

Only the prod cluster needs these. Neither is created by Terraform.

**Pool and ACL.** Create the pool, then grant `terraform@pve`
`TerraformProv` on it. The role carries no `Pool.*` privileges, so without
the per-pool ACL placement fails:

```bash
pvesh create /pools --poolid Talos-K8s
pveum acl modify /pool/Talos-K8s --users terraform@pve --roles TerraformProv
```

**Template.** `talos-tp` is the Image Factory `nocloud` disk image with the
`qemu-guest-agent` extension, imported into a VM and converted to a
template. Talos has no SSH and no package manager, so the guest agent
comes from the image, not from a playbook. The version and schematic must
match `talos_version` and `talos_schematic_id` in
`terraform/environments/prod/variables.tf` (today `v1.14.2` and
`ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`; the
schematic is the one for `siderolabs/qemu-guest-agent`). On `pve`:

```bash
TALOS=v1.14.2
SCHEMATIC=ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
cd /var/lib/vz/template/iso
wget -O talos-nocloud.raw.xz \
  "https://factory.talos.dev/image/$SCHEMATIC/$TALOS/nocloud-amd64.raw.xz"
xz -d talos-nocloud.raw.xz
qm create 5001 --name talos-tp --memory 2048 --cores 2 \
  --cpu x86-64-v2-AES --machine q35 --ostype l26 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 \
  --serial0 socket --agent enabled=1
qm importdisk 5001 talos-nocloud.raw local-lvm
qm config 5001 | grep unused      # note the volume name, normally vm-5001-disk-0
qm set 5001 --scsi0 local-lvm:vm-5001-disk-0,discard=on,iothread=1,ssd=1 \
  --boot order=scsi0 --ide2 local-lvm:cloudinit
qm template 5001
rm talos-nocloud.raw
```

The template needs the same ACL the Ubuntu template has, so that
`terraform@pve` can clone it. Confirm with `qm config 5001`: `agent:
enabled=1`, `scsi0` on `local-lvm`, `ide2` a cloudinit drive, and no `ipconfig0`
on the template itself.
````

- [ ] **Step 2: `docs/rebuild.md` — the rebuild order and caveats**

(a) In "Rebuild order" step 2 (the host preparation list), add `Talos-K8s` to the list of pools to create, with a pointer to section 2b. (b) After step 15, add:

````markdown
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

    The cluster's PKI exists only in `terraform.tfstate`, so a lost state
    means rebuilding the cluster, as for every other environment after an SSD
    replacement. Fetch `talosconfig` the same way as `kubeconfig` if you need
    `talosctl`: `terraform output -raw talosconfig > ~/.talos/config`.

    **Resizing a node.** Edit `memory` in `talos_nodes` and apply. The VM
    keeps running with the old size until restarted, because the module sets
    `automatic_reboot = false`. One node at a time: `kubectl drain`, then
    `qm reboot <vmid>` on `pve` (a guest-level `talosctl reboot` does not pick
    up the new size), then `kubectl uncordon`.
````

(c) In section 4's table of workstation-only files, add rows for `terraform/environments/prod/prod.tfvars` (Proxmox API token and the node map; recreate from `prod.tfvars.example`) and `terraform/environments/prod/terraform.tfstate` (holds the cluster PKI and the kubeconfig; if lost, rebuild the cluster). (d) In section 5's state-reset loop, change `for env in shared dev; do` to `for env in shared dev prod; do` only if the loop's body still makes sense for prod (it needs `prod.tfvars`, which exists by then); otherwise add a sentence after the loop.

- [ ] **Step 3: `README.md`**

Edit, reading each spot first:
- **Diagram:** change the `talos` node to a solid box with its machines: `talos["Talos cluster<br/>cp1 .110 · w1 .111 · w2 .112"]` (remove `:::planned`). Keep the dashed `talos -. "manages" .-> k8s` edge (that is sub-project 4). Update the line below the diagram if "Solid boxes run today" is no longer accurate.
- **"What actually runs" table:** add a `VMs` row: ``Talos prod cluster: one control plane and two workers, `.110`–`.112`; nodes only, no workloads yet`` | `terraform/environments/prod`, `terraform/modules/talos-node`.
- **Scope paragraph:** replace "One physical machine, one SSD, and one Kubernetes cluster: `dev`. There is no `prod` cluster yet. …" with a paragraph saying: one machine, one SSD, two Kubernetes clusters — `dev` (kubeadm, running the platform today) and `prod` (Talos, three nodes, no workloads yet; its ArgoCD and monitoring hub arrives in sub-project 3 of the roadmap, ADR 0012). Keep the Glance sentence that follows.
- **Layout block:** `environments/prod/    never-applied scaffolding` → `environments/prod/    the Talos prod cluster`; delete the `talos/` entry (3 lines); `vault-vm, talos-*` → `vault-vm, talos-node`.
- **CI section:** the `terraform` row says "`terraform/environments/dev` and `terraform/environments/shared`" → add `terraform/environments/prod`; delete the paragraph beginning "`terraform/environments/prod` is not in the `terraform` job".

Validate the Mermaid:

```bash
MP=/tmp/claude-1000/-home-ubuntu/bc3f83c2-866a-4656-bb7e-e3d055659db4/scratchpad/mp
[ -d "$MP" ] || cp -r /tmp/claude-1000/-home-ubuntu-homelab/8117f454-18c5-4189-8710-21560488049d/scratchpad/mp "$MP"
node "$MP/p.mjs" README.md
```
Expected: the parser reports the diagram valid. If the copy has no `node_modules`, `npm i mermaid jsdom` inside it. If the parser path is gone, say so in your report instead of skipping silently.

- [ ] **Step 4: `terraform/README.md`**

Read the file. Rewrite the intro paragraph (prod "is never-applied scaffolding" → the Talos prod cluster); in the module tree replace `talos-k8s/` and `talos-vm/` with a `talos-node/` entry listing its four files, matching the neighbours' format; replace the whole "Prod — not yet" section with a short "Prod" section (the root builds the three-node Talos cluster; applied from the operator's workstation with `-var-file=prod.tfvars`; its prerequisites are in `docs/rebuild.md` section 2b; CI validates it with the other two); replace the `modules/talos-vm` / `modules/talos-k8s` bullet with a `modules/talos-node` bullet (one Talos VM, full clone of `talos-tp`, static cloud-init address; used by `environments/prod`).

- [ ] **Step 5: `CLAUDE.md`**

(a) Stack paragraph: replace "Only the `dev` environment exists, plus `terraform/environments/shared` … Their prod halves (`nfs-prod`, `kv-prod`) are ready but unused until prod has nodes." with text saying: `dev` is the kubeadm cluster; `terraform/environments/prod` is the Talos cluster (three nodes via the `siderolabs/talos` provider, applied from the operator's workstation, no workloads until sub-project 3); `terraform/environments/shared` holds `nfs-01`, `vault-02` and the LAN LXCs. Keep the sentence about `nfs-prod` and `kv-prod` but say they stay unused until the hub platform lands. (b) Layout block: add `environments/prod/` ("the Talos prod cluster") and change `talos-*` to `talos-node`. (c) "How a change reaches the cluster" table row 1: `in environments/dev or environments/shared` → `in environments/dev, shared or prod`. (d) "Load-bearing" list: the `*.tfvars` bullet gains `prod.tfvars`; add one bullet: **Prod's cluster secrets live in `terraform.tfstate`.** The Talos PKI and the kubeconfig are in `environments/prod/terraform.tfstate` on the operator's workstation and nowhere else; `kubeconfig` and `talosconfig` are sensitive outputs that nothing writes to disk. Losing the state means rebuilding the cluster. (ADR [0021](docs/decisions/0021-talos-prod-via-terraform-provider.md)). Also: the "Resource pools are not created by Terraform" bullet is already general; leave it.

- [ ] **Step 6: ADR 0021, the index and 0012**

Create `docs/decisions/0021-talos-prod-via-terraform-provider.md`, matching the shape of ADR 0012 (read it and 0019 first):

```markdown
# 0021. Talos prod cluster through the Terraform provider

**Status:** Accepted (2026-10-01)

## Context

Prod is a Talos cluster (ADR [0012](0012-hub-and-spoke-topology.md)). A
Talos cluster needs generated secrets and machine configs, and the secrets
must stay out of this public repository. The previous scaffolding generated
them by hand with `talosctl` into files under `talos/`, which could not be
applied. The host has about 6.5G of RAM available (measured 2026-10-01),
not the roadmap's 10G for prod.

## Decision

Terraform builds everything. `modules/talos-node` full-clones a `talos-tp`
template, built by hand from the Image Factory `nocloud` disk image with the
`siderolabs/qemu-guest-agent` extension (schematic
`ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`, Talos
`v1.14.2`), and gives each clone a static address through Proxmox cloud-init.
The `siderolabs/talos` provider (`0.12.0`) generates the secrets and machine
configs, applies them to the nodes' static addresses, bootstraps the control
plane and fetches the kubeconfig. The cluster's secrets exist only in
`terraform.tfstate`; `kubeconfig` and `talosconfig` are sensitive outputs and
no file is ever written. The cluster is one control plane and two workers, no
VIP, starting at 2G each (6G).

Rejected: `talosctl gen config` with SOPS-encrypted files committed (a key to
manage and a manual `apply-config` and `bootstrap` per node), and `talosctl`
with local gitignored output (the same manual steps and a second place to
lose secrets). Rejected for addressing: the `metal` image with DHCP at first
boot, which needs each node's temporary address found before its config can
move it.

## Consequences

One `terraform apply` goes from blank clones to a kubeconfig. Losing the
state loses the cluster's PKI, so the cluster is rebuilt, as every
environment is after an SSD replacement. The Talos version, schematic and
template must agree; changing the extension list means a new schematic and a
new template. Nodes start at 2G, Talos's documented minimum, leaning on swap;
growing them is a tfvars change plus a restart per node, and shrinking
`claude-code` (sub-project 4) is the first lever if 2G proves too small. The
Proxmox host steps (pool, ACL, template) stay manual in `docs/rebuild.md`; a
script for them is a follow-up.

## Related

`docs/superpowers/specs/2026-10-01-talos-prod-design.md`;
[#66](https://github.com/maxim-grin/homelab/pull/66).
```

Add the row to the table in `docs/decisions/README.md`, after the last row, in the same column format: `| [0021](0021-talos-prod-via-terraform-provider.md) | Talos prod cluster through the Terraform provider, secrets in state | Accepted | 2026-10-01 |`. In ADR 0012, change `**Status:** Accepted (2026-09-26), not yet built` to `**Status:** Accepted (2026-09-26); prod built per [0021](0021-talos-prod-via-terraform-provider.md)`, and in its Consequences paragraph replace the sentences saying prod and `talos/` "remain scaffolding until sub-project 2 …" and that CI "validates only `dev` and `shared`" with one sentence: sub-project 2 built the prod cluster (0021) and CI now validates `prod` with the other two roots. Do not edit 0012's Context or Decision. Also set the index row for 0012 to `Accepted, prod built (0021)`.

- [ ] **Step 7: Fact-check the ADR against the repo**

Run each and compare with the ADR text:

```bash
grep -n 'default' terraform/environments/prod/variables.tf | grep -E 'v1\.14\.2|ce4c9805'
grep -n 'version' terraform/environments/prod/versions.tf
grep -n 'memory' terraform/environments/prod/prod.tfvars.example
```
Expected: the version, schematic, provider pin and the 2048 sizes in the ADR match the files. Fix the ADR, not the code, if they differ. The controller will also have the ADR independently fact-checked.

- [ ] **Step 8: Check every doc claim**

```bash
grep -rIn "never-applied\|never applied\|talos-k8s\|talos-vm\|talos/_out\|the Mac\|the laptop" --exclude-dir=.git . | grep -v "^./docs/superpowers/\(specs\|plans\)/"
pre-commit run --all-files
```
Expected: the grep finds nothing (the history in `docs/superpowers/specs` and `plans` is allowed to mention them; the Talos design spec and this plan legitimately contain `talos-k8s` as a name to delete); `pre-commit` passes everywhere. Fix findings.

- [ ] **Step 9: Commit**

```bash
git add docs README.md terraform/README.md CLAUDE.md
git commit -m "docs: document the talos prod cluster" -m "rebuild.md gains the pool, template and bring-up steps. README,
terraform/README and CLAUDE.md describe prod as real. ADR 0021 records
the provider-based design; 0012's status points to it."
```

---

### Task 7: Final verification

**Files:** none modified, except fixes found here.

**Interfaces:**
- Consumes: Tasks 1-6.
- Produces: a branch ready for the operator to apply.

- [ ] **Step 1: Full local CI**

```bash
pre-commit run --all-files
for env in dev shared prod; do
  terraform -chdir=terraform/environments/$env init -backend=false -input=false >/dev/null
  terraform -chdir=terraform/environments/$env validate
  tflint --chdir=terraform/environments/$env --config="$PWD/.tflint.hcl"
done
terraform -chdir=terraform/environments/prod test
scripts/check-manifests.sh
```
Expected: all pass (the manifests script needs `kustomize`, `helm`, `yq`, `kubeconform`; if one is missing, say which and skip only that).

- [ ] **Step 2: Nothing secret or generated is tracked or untracked**

```bash
git status --porcelain
git ls-files | grep -E 'tfstate|\.tfvars$|kubeconfig|talosconfig|secrets\.yaml$' ; echo "exit=$?"
git check-ignore -v terraform/environments/prod/terraform.tfstate terraform/environments/prod/prod.tfvars
```
Expected: `git status` is clean; the `ls-files` grep prints only `ansible/secret.yaml`-style encrypted files that were already tracked (none under `terraform/environments/prod`) and `exit=1` or only those; both `check-ignore` lines match a rule.

- [ ] **Step 3: The PR description lists the operator's steps**

Append to the PR description (body file, then `gh pr edit 66 --body-file <file>`; no generated-with footer) a section "Operator steps, in order" that quotes `docs/rebuild.md` section 2b (pool, ACL, template) and step 16 (init, apply, outputs, `kubectl get nodes`), notes the RAM situation (apply at 2G/2G/2G, grow later), and notes "README says prod runs; true once you apply".

- [ ] **Step 4: Mark ready**

Run: `gh pr ready 66`, then `gh pr view 66 --json isDraft,statusCheckRollup`. Expected: `isDraft: false`; CI checks pending or passing. Report any failing check with its log tail.

- [ ] **Step 5: Commit any fixes made in this task**

If Steps 1-2 needed fixes: commit them with `fix:` or `docs:` subjects and push. Otherwise nothing to commit.
