# Vault VM Infrastructure Implementation Plan (PRs 1-2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `vault-02` (vmid 105, `10.0.0.133`) as an empty VM in `proxmox/environments/shared`, and give `nfs-01` a `/srv/nfs/backups` share exported to it alone — the two prerequisites the new Vault needs, neither of which touches the running `vault-01` LXC.

**Architecture:** A new `proxmox/modules/vault-vm` (copied from `modules/nfs-server`, one data disk instead of two) is instantiated in the shared root; no `import` block, because the machine does not exist yet. `modules/nfs-server` gains a third disk, and the `nfs_server` role gains a third share with a per-share `mode`, exported only to the Vault VM's address.

**Tech Stack:** Terraform 1.16 + `telmate/proxmox` 3.0.2-rc10, tflint, Ansible (ansible-lint profile production), nfs-kernel-server.

**Spec:** `docs/superpowers/specs/2026-09-25-vault-vm-design.md`

**Scope:** PRs 1 and 2 of the spec's five. PR 3 (the Vault role rebuild), PR 4 (cutover) and PR 5 (decommission of the LXC) get their own plan once these are applied.

## Global Constraints

- Two branches: `vault-vm` (exists, holds the spec commits) for PR 1, and `nfs-backups-share` cut from `main` after PR 1 merges for PR 2. Never commit to `main`, never merge, never push to `main`. An agent's job ends at an open PR.
- Commits: Conventional Commits, subject ≤ 50 chars, imperative, lowercase, no trailing period, body wrapped at 72. Types: `feat fix refactor docs chore ops`.
- **No `Co-Authored-By` trailer and no "generated with" line** in commits or PR bodies. CLAUDE.md overrides any default attribution.
- `vault-02`: vmid **105**, name `vault-02`, pool `VM`, 2 cores, **2048 MB**, OS disk **20G**, data disk **10G** on `scsi1`, IP `10.0.0.133/24`, `startup = "order=5,up=20"`, `start_at_node_boot = true`, `automatic_reboot = false`.
- Backups share: `scsi3` on `nfs-01`, **10G**, label `nfs-backups`, path `/srv/nfs/backups`, mode **0700**, exported to `10.0.0.133` **only**.
- The existing shares keep mode `0777` and their current clients. `/srv/nfs/k8s` is never renamed.
- **The `vault-01` LXC (vmid 104) is not touched by either PR** — not in Terraform, not in the inventory, not in the role. It keeps serving until PR 5.
- Never run `terraform plan`/`apply` against Proxmox; validate from a `git archive` copy. Never run a playbook against a real host. Never decrypt or pass `ansible/secret.yaml`.
- Tools: `terraform`, `tflint`, `kubectl`, `ansible-lint`, `pre-commit` on PATH; `ansible*` binaries at `/home/ubuntu/.local/share/uv/tools/ansible-lint/bin` (pipe output through `| cat`). `SCRATCH` is the session scratchpad directory.
- Read narrowly: `grep -n`, `sed -n`, `head`/`tail`. Do not `cat` a whole file to inspect part of it.

## File Map

| File | Change | Responsibility |
| --- | --- | --- |
| `proxmox/modules/vault-vm/{versions,variables,main,outputs}.tf` | create | The Vault VM with one data disk |
| `proxmox/environments/shared/{main,variables}.tf`, `shared.tfvars.example` | modify | Instantiates it |
| `ansible/inventories/shared/hosts.yaml` | modify | `vault_vm` group |
| `proxmox/README.md` | modify | Where the VM lives |
| `proxmox/modules/nfs-server/{main,variables}.tf` | modify | `scsi3` |
| `ansible/roles/nfs_server/{defaults,tasks,templates}` | modify | Third share, per-share mode |
| `docs/rebuild.md` | modify | Capacity and the new share |

**PR boundary:** Tasks 1-4 are PR 1. Task 5 is its operator run. Tasks 6-9 are PR 2, Task 10 its operator run.

---

### Task 1: The `vault-vm` Terraform module

**Files:**
- Create: `proxmox/modules/vault-vm/versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`
- Reference (read, do not modify): `proxmox/modules/nfs-server/*`

**Interfaces:**
- Produces: module `vault-vm`, resource `proxmox_vm_qemu.vault_vm`; inputs `vm_name, target_node, vmid, pool, clone_template, full_clone, memory, cpu_cores, start_at_node_boot, startup, disk_size, vault_data_disk_size, disk_storage, cloudinit_storage, network_bridge, network_firewall, ci_user, ci_password, ssh_public_key, ip_config, tags`; outputs `vm_id, vm_name, vm_mac, vm_ip_config`.

- [x] **Step 1: Copy the module**

```bash
mkdir -p proxmox/modules/vault-vm
cp proxmox/modules/nfs-server/versions.tf proxmox/modules/vault-vm/versions.tf
cp proxmox/modules/nfs-server/variables.tf proxmox/modules/vault-vm/variables.tf
cp proxmox/modules/nfs-server/main.tf proxmox/modules/vault-vm/main.tf
cp proxmox/modules/nfs-server/outputs.tf proxmox/modules/vault-vm/outputs.tf
```

- [x] **Step 2: Adapt `variables.tf`**

Replace the two data-disk variables with one:

```hcl
# The Raft store lives here rather than on the OS disk, so Vault's data can
# be sized, grown and reasoned about on its own. Sizes only go up: Proxmox
# cannot shrink a disk.
variable "vault_data_disk_size" {
  description = "Size of the Vault data disk (scsi1), mounted at /var/lib/vault"
  type        = string
}
```

Delete `nfs_dev_disk_size` and `nfs_prod_disk_size`. Change `tags`'s default to `"ubuntu,vault"`. Every other variable stays.

- [x] **Step 3: Adapt `main.tf`**

- Rename the resource to `proxmox_vm_qemu.vault_vm`.
- Replace the file's header comment with:

```hcl
# A copy of modules/ubuntu-vm with one data disk for Vault's Raft store.
# Unlike modules/nfs-server this VM is created by Terraform rather than
# imported, so the hard-coded settings need not match an existing machine --
# but they are kept identical to ubuntu-vm anyway, so the three VM modules
# stay comparable.
```

- Delete the `scsi2` block entirely.
- In `scsi1`, `size = var.vault_data_disk_size`, and put this comment above the block:

```hcl
      # /var/lib/vault. Raft keeps Vault's state here; an audit log that
      # cannot be written stops Vault answering requests, so this disk's
      # free space is operationally load-bearing.
```

- Keep `automatic_reboot = false` and its comment, adapted: a change that needs a reboot must never bounce the root of trust unattended.
- Keep `lifecycle.ignore_changes = [power_state, clone, full_clone]`. `clone`/`full_clone` are not strictly needed on a created VM, but they cost nothing and make a later adoption safe.

- [x] **Step 4: Adapt `outputs.tf`** — rename every `proxmox_vm_qemu.nfs_server` reference to `proxmox_vm_qemu.vault_vm`; the four outputs keep their names and descriptions, with "NFS server VM" becoming "Vault VM".

- [x] **Step 5: Check nothing of the NFS module leaked through**

```bash
grep -rn -i "nfs" proxmox/modules/vault-vm/ || echo "clean"
grep -n "scsi" proxmox/modules/vault-vm/main.tf
```

Expected: `clean`, and exactly `scsi0`, `scsi1` (plus the `scsi` block opener and `scsihw`). Any `scsi2` or `nfs` is a copy error.

- [x] **Step 6: Validate**

```bash
cd proxmox/modules/vault-vm && terraform init -backend=false -input=false >/dev/null && terraform validate && terraform fmt -check && tflint --config=/home/ubuntu/homelab/.tflint.hcl; rm -rf .terraform .terraform.lock.hcl
```

Expected: `Success! The configuration is valid.`, no fmt or tflint output.

- [x] **Step 7: Commit**

```bash
git add proxmox/modules/vault-vm
git commit -m "feat: add vault-vm terraform module" -m "A copy of nfs-server with one data disk for Vault's raft store."
```

---

### Task 2: Instantiate `vault-02` in the shared root

**Files:**
- Modify: `proxmox/environments/shared/main.tf` (append), `proxmox/environments/shared/variables.tf` (append), `proxmox/environments/shared/shared.tfvars.example` (append)

**Interfaces:**
- Consumes: module `../../modules/vault-vm` from Task 1, and the shared root's existing `pm_target_node`, `clone_template_ubuntu`, `ci_user`, `ci_password`, `ssh_public_key`, `gateway`.
- Produces: `module.vault_vm` in the shared root; new variable `vault_vm_ip`; output `vault_vm_details`.

- [x] **Step 1: Append the module call to `main.tf`**

```hcl
################################################################################
# HashiCorp Vault
################################################################################
module "vault_vm" {
  source = "../../modules/vault-vm"

  # Basic VM Configuration
  vm_name     = "vault-02"
  vmid        = 105
  target_node = var.pm_target_node
  pool        = "VM"

  clone_template = var.clone_template_ubuntu
  full_clone     = true

  # Resource Allocation
  # Raft plus a handful of KV paths. The LXC it replaces ran in 1 GiB; the
  # extra gigabyte is headroom for the audit log and snapshot runs.
  memory    = 2048
  cpu_cores = 2

  # OS disk, then the Raft store on its own disk.
  disk_size            = "20G"
  vault_data_disk_size = "10G"
  disk_storage         = "local-lvm"

  # First up, ahead of nfs-01 at order=10 and the cluster at 20/30. Vault is
  # the root of trust: when it is sealed or absent, argocd-vault-plugin
  # renders nothing and every Application carrying a <path:...> placeholder
  # fails to sync.
  start_at_node_boot = true
  startup            = "order=5,up=20"

  # Network Configuration
  network_firewall = true
  ip_config        = format("ip=%s,gw=%s", var.vault_vm_ip, var.gateway)

  # Cloud-init Settings
  ci_user        = var.ci_user
  ci_password    = var.ci_password
  ssh_public_key = var.ssh_public_key

  # OS configuration lives in the ansible/ vault role, run against
  # ansible/inventories/shared. This VM is empty until that runs; the
  # vault-01 LXC keeps serving until then.

  # Tags
  tags = "ubuntu,vault,shared"
}
```

- [x] **Step 2: Append the variable**

```hcl
# Vault VM Variables
variable "vault_vm_ip" {
  description = "Vault VM IP with CIDR (e.g. '10.0.0.133/24')"
  type        = string
}
```

and to `shared.tfvars.example`:

```hcl
# Vault VM. Must include CIDR. Confirm it is outside the router's DHCP pool
# before applying -- every VM here takes a static address and the pool has
# not been checked against them.
vault_vm_ip = "10.0.0.133/24"
```

- [x] **Step 3: Append the output to `outputs.tf`**

```hcl
# Vault VM Output
output "vault_vm_details" {
  value = {
    id   = module.vault_vm.vm_id
    name = module.vault_vm.vm_name
    mac  = module.vault_vm.vm_mac
    ip   = module.vault_vm.vm_ip_config
  }
}
```

- [x] **Step 4: Confirm no collision with the existing NFS module**

```bash
grep -n -E "vmid|^module|startup" proxmox/environments/shared/main.tf
```

Expected: `module "nfs"` with vmid 103 at `order=10,up=30`, and `module "vault_vm"` with vmid 105 at `order=5,up=20`. Two modules, two vmids, no repetition.

- [x] **Step 5: Validate the root**

```bash
cd /home/ubuntu/homelab
S=$(mktemp -d); git archive HEAD proxmox | tar -x -C $S
cp -r proxmox/modules/vault-vm $S/proxmox/modules/
cp proxmox/environments/shared/*.tf $S/proxmox/environments/shared/
(cd $S/proxmox/environments/shared && terraform init -backend=false -input=false >/dev/null && terraform validate && tflint --config=/home/ubuntu/homelab/.tflint.hcl && echo OK)
rm -rf $S
terraform fmt -recursive -check proxmox && echo "fmt ok"
```

Expected: `Success!`, `OK`, no tflint output, `fmt ok`.

- [x] **Step 6: Commit**

```bash
git add proxmox/environments/shared
git commit -m "feat: add the vault-02 vm to the shared root" -m "vmid 105 at 10.0.0.133, empty until the vault role runs. The vault-01
LXC is untouched and keeps serving."
```

---

### Task 3: Inventory and README

**Files:**
- Modify: `ansible/inventories/shared/hosts.yaml` (add group `vault_vm`)
- Modify: `proxmox/README.md` (tree and module list)

**Interfaces:**
- Consumes: `host_ips['vault-02']`, `proxmox_vm_ids['vault-02']` — added to `secret.yaml` by the operator, not by an agent.
- Produces: group `vault_vm` holding host `vault-02`, resolvable with `-i inventories/shared`.

- [x] **Step 1: Add the group**

Under `children:` in `ansible/inventories/shared/hosts.yaml`, after `nfs`:

```yaml
    # The Vault VM that replaces the vault-01 LXC. It is a cloud-init Ubuntu
    # VM, so it uses the all-level ansible_user -- unlike the LXC, whose
    # Debian template has only root. Both exist until the cutover; this group
    # is named vault_vm so the old vault group keeps working meanwhile.
    vault_vm:
      hosts:
        vault-02:
          ansible_host: "{{ host_ips['vault-02'] }}"
          proxmox_vm_id: "{{ proxmox_vm_ids['vault-02'] }}"
```

- [x] **Step 2: Verify the inventory parses**

```bash
cd ansible && /home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-inventory -i inventories/shared --graph 2>&1 | cat
```

Expected: `@nfs` with `nfs-01` and `@vault_vm` with `vault-02`. `host_ips` is undefined without `secret.yaml`, which is fine — the graph shows structure, not values.

- [x] **Step 3: Update `proxmox/README.md`**

Add `modules/vault-vm/` to the tree beside `nfs-server/` (same four files), extend the `environments/shared/` description to name both machines, and add to the module list:

```markdown
- **modules/vault-vm** – `ubuntu-vm` plus one data disk for Vault's raft store; backs `vault-02` (vmid 105) in `environments/shared`.
```

- [x] **Step 4: Lint and commit**

```bash
cd ansible && ansible-lint . 2>&1 | tail -2; cd ..
pre-commit run --files ansible/inventories/shared/hosts.yaml proxmox/README.md
git add ansible/inventories/shared/hosts.yaml proxmox/README.md
git commit -m "feat: add vault-02 to the shared inventory"
```

Expected: ansible-lint `Passed`, all hooks Passed.

---

### Task 4: Review and open PR 1

- [x] **Step 1: Full verification**

```bash
cd /home/ubuntu/homelab
S=$(mktemp -d); git archive HEAD proxmox | tar -x -C $S
for d in environments/dev environments/shared modules/vault-vm; do (cd $S/proxmox/$d && terraform init -backend=false -input=false >/dev/null && terraform validate >/dev/null && tflint --config=/home/ubuntu/homelab/.tflint.hcl && echo "OK $d") || echo "FAIL $d"; done; rm -rf $S
terraform fmt -recursive -check proxmox && echo "fmt ok"
cd ansible && ansible-lint . 2>&1 | tail -2; cd ..
pre-commit run --all-files
git status --short
```

Expected: three `OK`, no `FAIL`, `fmt ok`, ansible-lint `Passed`, all hooks Passed, clean tree.

- [x] **Step 2: Code review** — invoke `superpowers:requesting-code-review` against the branch diff from `main`. Fix findings on the branch.

- [x] **Step 3: Pre-merge checks** — invoke `superpowers:finishing-a-development-branch`; choose "push and create a Pull Request". Never merge.

- [x] **Step 4: Write the PR body** to `$SCRATCH/pr-vault-vm.md`:

```markdown
First of five PRs replacing the `vault-01` LXC with a purpose-built VM.
This one only creates the machine: `vault-02`, vmid 105, `10.0.0.133`,
2 cores, 2 GiB, a 20G OS disk and a 10G data disk for Vault's raft store.

**Nothing uses it yet and nothing changes.** The `vault-01` LXC (vmid 104) is
untouched and keeps serving every `<path:...>` placeholder until PR 4 cuts
over and PR 5 retires it.

Spec: `docs/superpowers/specs/2026-09-25-vault-vm-design.md`
Plan: `docs/superpowers/plans/2026-09-25-vault-vm-infra.md`

## Operator steps (plan Task 5)

1. Confirm vmid 105 is free (`qm list; pct list`) and that `10.0.0.133` is
   outside the router's DHCP pool. Every VM here takes a static address and
   the pool has not been checked against them.
2. Add `vault-02` to `host_ips` and `proxmox_vm_ids` in `secret.yaml`, and
   `vault_vm_ip = "10.0.0.133/24"` to `shared.tfvars`.
3. `terraform plan -var-file=shared.tfvars` — **1 to add, 0 to change, 0 to
   destroy**; `module.nfs` must not appear. Apply.
4. `qm config 105 | grep -E '^(scsi|memory|cores|startup|onboot)'`, then
   `ssh ubuntu@10.0.0.133` and `lsblk` — a 20G root and an empty 10G disk.
5. `pct status 104` still running, dev apps still Synced: this PR must not
   have touched the old Vault.

## Checks

- `terraform validate` / `fmt` / `tflint` on dev, shared and the new module
- `ansible-lint` (production), inventory graph shows `@vault_vm`
- `pre-commit run --all-files`
```

- [x] **Step 5: Push and open**

```bash
git push -u origin vault-vm
gh pr create --base main --head vault-vm --title "feat: add the vault-02 vm" --body-file $SCRATCH/pr-vault-vm.md
```

Report the URL. Do not merge. Then close PR #34 with a comment pointing at the new spec:

```bash
gh pr close 34 --comment "Superseded by the vault-vm design: a new VM needs no import, so the LXC move this PR performs is no longer the plan. See docs/superpowers/specs/2026-09-25-vault-vm-design.md."
```

---

### Task 5: Operator steps for PR 1 (repository owner)

Not for agents. In order; any unexpected output, stop and report.

- [x] **Step 1: Pre-flight**

```bash
qm list; pct list                       # 105 unused
arping -c3 -I vmbr0 10.0.0.133          # no answer
```

Check the router's DHCP pool excludes `10.0.0.133`. If it does not, shrink the pool — that protects the eight static addresses already in use, not just this one.

- [x] **Step 2: Secrets and tfvars**

Add to `secret.yaml` (`ansible-vault edit`): `host_ips['vault-02'] = 10.0.0.133`, `proxmox_vm_ids['vault-02'] = 105`. Add `vault_vm_ip = "10.0.0.133/24"` to `shared.tfvars`.

- [x] **Step 3: Apply**

```bash
cd proxmox/environments/shared
terraform plan -var-file=shared.tfvars    # 1 to add, 0 to change, 0 to destroy
terraform apply -var-file=shared.tfvars
```

`module.nfs` appearing in that plan means something else drifted — stop and paste it.

- [x] **Step 4: Verify**

```bash
qm config 105 | grep -E '^(scsi|memory|cores|startup|onboot)'
ssh ubuntu@10.0.0.133 'lsblk -o NAME,SIZE,FSTYPE; ls -l /dev/disk/by-id/ | grep drive-scsi'
pct status 104
kubectl -n argocd get applications
```

Expected: three disks' worth of config (scsi0, scsi1, cloud-init), an empty `sdb`, `...drive-scsi1` present, the LXC still running, apps still `Synced`. **Report the `by-id` names** — PR 3's role uses them.

---

### Task 6: `scsi3` on the NFS server

Start PR 2 only after PR 1 is merged: `git checkout main && git pull && git checkout -b nfs-backups-share`.

**Files:**
- Modify: `proxmox/modules/nfs-server/variables.tf` (add `nfs_backups_disk_size`), `proxmox/modules/nfs-server/main.tf` (add `scsi3`)
- Modify: `proxmox/environments/shared/main.tf` (pass `"10G"`)

**Interfaces:**
- Produces: a third data disk on vmid 103, appearing in the guest as `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3`, consumed by Task 7.

- [x] **Step 1: Add the variable**

```hcl
variable "nfs_backups_disk_size" {
  description = "Size of the backups data disk (scsi3)"
  type        = string
}
```

- [x] **Step 2: Add the disk**

After the `scsi2` block in `proxmox/modules/nfs-server/main.tf`, with the same ten attributes as its siblings and `size = var.nfs_backups_disk_size`. Above it:

```hcl
      # Vault's raft snapshots. Its own disk so a filling backup directory
      # cannot stop the clusters writing PVCs, and so the share above it can
      # be exported to one host with different permissions.
```

- [x] **Step 3: Pass the size in the shared root**

In `module "nfs"`, after `nfs_prod_disk_size`:

```hcl
  nfs_backups_disk_size = "10G"
```

- [x] **Step 4: Validate**

```bash
cd /home/ubuntu/homelab
S=$(mktemp -d); git archive HEAD proxmox | tar -x -C $S
cp proxmox/modules/nfs-server/*.tf $S/proxmox/modules/nfs-server/
cp proxmox/environments/shared/*.tf $S/proxmox/environments/shared/
(cd $S/proxmox/environments/shared && terraform init -backend=false -input=false >/dev/null && terraform validate && echo OK); rm -rf $S
terraform fmt -recursive -check proxmox && echo "fmt ok"
grep -c "scsi[0-9] {" proxmox/modules/nfs-server/main.tf
```

Expected: `Success!`, `OK`, `fmt ok`, and 4 scsi blocks.

- [x] **Step 5: Commit**

```bash
git add proxmox/modules/nfs-server proxmox/environments/shared
git commit -m "feat: add a backups disk to nfs-01" -m "scsi3, 10G, for Vault's raft snapshots."
```

---

### Task 7: The backups share in the `nfs_server` role

**Files:**
- Modify: `ansible/roles/nfs_server/defaults/main.yaml`
- Modify: `ansible/roles/nfs_server/tasks/main.yaml` (the `Open each share's root` task)
- Test (scratch): `$SCRATCH/nfs-backups-test.yaml`

**Interfaces:**
- Consumes: `host_ips['vault-02']`; the `scsi3` device from Task 6.
- Produces: a third `nfs_server_shares` entry with `mode: "0700"`; a per-share `mode` defaulting to `0777`; `nfs_server_backup_clients`.

- [x] **Step 1: Write the failing test**

Create `$SCRATCH/nfs-backups-test.yaml`:

```yaml
- name: The backups share is exported to the Vault VM alone, and the k8s shares are unchanged
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - /home/ubuntu/homelab/ansible/roles/nfs_server/defaults/main.yaml
  vars:
    host_ips:
      master-01: 10.0.0.101
      worker-01: 10.0.0.201
      worker-02: 10.0.0.202
      vault-02: 10.0.0.133
  tasks:
    - name: Render exports.j2
      ansible.builtin.set_fact:
        rendered: "{{ lookup('ansible.builtin.template', '/home/ubuntu/homelab/ansible/roles/nfs_server/templates/exports.j2') }}"

    - name: The backups line names only the Vault VM
      ansible.builtin.assert:
        that:
          - "'/srv/nfs/backups 10.0.0.133(rw,sync,no_subtree_check,no_root_squash)' in rendered.splitlines()"
          - "'/srv/nfs/backups' not in (rendered | regex_replace('/srv/nfs/backups [^\\n]*', ''))"
        fail_msg: "{{ rendered }}"

    - name: No cluster node may read the backups share
      ansible.builtin.assert:
        that:
          - "'10.0.0.101' not in (rendered.splitlines() | select('search', '/srv/nfs/backups') | join(' '))"
          - "'10.0.0.201' not in (rendered.splitlines() | select('search', '/srv/nfs/backups') | join(' '))"

    - name: The dev share still lists the three nodes and prod still has no line
      ansible.builtin.assert:
        that:
          - "'/srv/nfs/k8s 10.0.0.101(rw,sync,no_subtree_check,no_root_squash) 10.0.0.201(rw,sync,no_subtree_check,no_root_squash) 10.0.0.202(rw,sync,no_subtree_check,no_root_squash)' in rendered.splitlines()"
          - "'/srv/nfs/prod' not in rendered"

    - name: Modes are per share, and only backups is restricted
      ansible.builtin.assert:
        that:
          - "(nfs_server_shares | selectattr('name', 'equalto', 'backups') | map(attribute='mode') | first) == '0700'"
          - "(nfs_server_shares | rejectattr('name', 'equalto', 'backups') | map(attribute='mode', default='0777') | unique | list) == ['0777']"
```

- [x] **Step 2: Run it to verify it fails**

```bash
/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i localhost, $SCRATCH/nfs-backups-test.yaml 2>&1 | cat
```

Expected: FAIL on the first assertion — there is no backups share yet.

- [x] **Step 3: Add the share and its clients to the defaults**

Append the third entry to `nfs_server_shares`:

```yaml
  - name: backups
    device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
    path: /srv/nfs/backups
    # 0700 where the k8s shares are 0777: a Vault raft snapshot is every
    # secret in one file. Only root on vault-02 writes or reads it, and the
    # export below admits no other host.
    mode: "0700"
    clients: "{{ nfs_server_backup_clients }}"
```

and after `nfs_server_prod_clients`:

```yaml
# The Vault VM alone. Not the cluster subnet, not the k8s nodes: a snapshot
# of Vault is every secret it holds, and the only machine that needs to read
# one is the machine that wrote it.
nfs_server_backup_clients: "{{ ['vault-02'] | map('extract', host_ips) | list }}"
```

Add `mode: "0777"` explicitly to the `dev` and `prod` entries, so every share states its own mode rather than two of them relying on a default.

- [x] **Step 4: Make the directory task use the share's mode**

In `ansible/roles/nfs_server/tasks/main.yaml`, the `Open each share's root to the provisioner` task: rename it to `Set each share's root permissions`, and change `mode: "0777"` to `mode: "{{ item.mode }}"`. Keep the existing comment about 0777 and the provisioner, and add that the backups share is 0700 for the opposite reason.

- [x] **Step 5: Run the test again**

Same command as Step 2. Expected: all four assertion tasks pass, `failed=0`.

- [x] **Step 6: Confirm the drop-in and the guard pick the share up automatically**

```bash
grep -n "RequiresMountsFor" ansible/roles/nfs_server/templates/requires-mounts.conf.j2
grep -n "nfs_server_shares" ansible/roles/nfs_server/tasks/main.yaml | head
```

Expected: the drop-in maps over `nfs_server_shares | map(attribute='path')`, and the find/assert/filesystem/mount tasks all loop over `nfs_server_shares` — so the third share needs no further wiring. If any of them enumerates shares by name instead, stop and report.

- [x] **Step 7: Lint and syntax-check**

```bash
cd ansible && ansible-lint . && /home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/shared playbooks/nfs_server.yaml --syntax-check 2>&1 | cat
```

Expected: `Passed: 0 failure(s), 0 warning(s)`; `playbook: playbooks/nfs_server.yaml`.

- [x] **Step 8: Commit**

```bash
git add ansible/roles/nfs_server
git commit -m "feat: export a backups share to the vault vm" -m "Vault's raft snapshots land on their own disk, mode 0700, exported to
vault-02 alone. Shares now carry their own mode."
```

---

### Task 8: Documentation for the share

**Files:**
- Modify: `docs/rebuild.md` (the disk-capacity section; the NFS playbook step if it enumerates shares)

- [x] **Step 1: Update the capacity paragraph**

The section already records that `nfs-01` gained two 50 GiB disks and the nodes went to 30 GiB. Add the backups disk: 10 GiB on `scsi3` for Vault's raft snapshots, 14 kept, and that the pool is thin so the declared total keeps drifting further above the physical 141 GiB — watch actual use, act at about 80%.

- [x] **Step 2: Check whether anything else enumerates the shares**

```bash
grep -rn "srv/nfs" docs/ README.md CLAUDE.md ansible/README.md | grep -v superpowers
```

Expected: any place that lists the shares now needs `/srv/nfs/backups` beside `/srv/nfs/k8s` and `/srv/nfs/prod`. Update those; leave prose about the dev share's path alone.

- [x] **Step 3: pre-commit and commit**

```bash
pre-commit run --all-files
git add docs/rebuild.md README.md CLAUDE.md ansible/README.md
git commit -m "docs: record the nfs backups share"
```

Commit only the files you actually changed.

---

### Task 9: Review and open PR 2

- [x] **Step 1: Full verification** — as Task 4 Step 1, plus `scripts/check-manifests.sh`.

- [x] **Step 2: Code review** — `superpowers:requesting-code-review`, fix findings.

- [x] **Step 3: Pre-merge checks** — `superpowers:finishing-a-development-branch`, push and open a PR, never merge.

- [x] **Step 4: PR body** to `$SCRATCH/pr-nfs-backups.md`, covering: what it adds (a 10G `scsi3` disk on `nfs-01`, a `/srv/nfs/backups` share at mode 0700 exported to `10.0.0.133` only), that the k8s shares are unchanged, and the operator steps from Task 10 including the `qm set` workaround and why (the provider refuses to hot-attach and we will not reboot `nfs-01`).

- [x] **Step 5: Push and open**

```bash
git push -u origin nfs-backups-share
gh pr create --base main --head nfs-backups-share --title "feat: add a backups share for vault snapshots" --body-file $SCRATCH/pr-nfs-backups.md
```

---

### Task 10: Operator steps for PR 2 (repository owner)

Not for agents.

- [x] **Step 1: Attach the disk by hand**

The provider refused to hot-attach `scsi1`/`scsi2` and demanded a reboot; `nfs-01` serves every PVC, so it is attached on the host instead and Terraform reconciles:

```bash
qm set 103 -scsi3 local-lvm:10,cache=none,discard=on,iothread=1,ssd=1
qm config 103 | grep '^scsi3'
```

- [x] **Step 2: Reconcile**

```bash
cd proxmox/environments/shared
terraform plan -var-file=shared.tfvars
```

Expected: no disk changes and no reboot demand — at most bookkeeping. If it wants to change `scsi3`, the `qm set` flags did not match the module; paste the plan. Then apply.

- [x] **Step 3: Run the role**

```bash
cd ansible
ansible-playbook -i inventories/shared playbooks/nfs_server.yaml -e @secret.yaml --ask-vault-pass
```

Expected: the guard passes (`/srv/nfs/backups` does not exist yet), the filesystem is created and labelled `nfs-backups`, the mount is `changed`, and the published exports list `/srv/nfs/k8s` for the three nodes and `/srv/nfs/backups` for `10.0.0.133` — and still nothing for prod.

- [x] **Step 4: Verify**

```bash
# on nfs-01
findmnt /srv/nfs/backups
ls -ld /srv/nfs/backups          # drwx------ root root
cat /etc/exports
showmount -e localhost
systemctl show nfs-server -p RequiresMountsFor
sudo reboot
# after it returns
findmnt /srv/nfs/backups && showmount -e localhost
kubectl get pvc -A               # from the workstation: all still Bound
```

- [x] **Step 5: Prove the export really is restricted**

From a cluster node (which must be refused) and from `vault-02` (which must succeed):

```bash
ssh ubuntu@10.0.0.201 'showmount -e 10.0.0.131; sudo mount -t nfs 10.0.0.131:/srv/nfs/backups /mnt 2>&1 | tail -1'
ssh ubuntu@10.0.0.133 'sudo mkdir -p /mnt/t && sudo mount -t nfs 10.0.0.131:/srv/nfs/backups /mnt/t && sudo touch /mnt/t/probe && ls -l /mnt/t && sudo umount /mnt/t'
```

Expected: the worker's mount is refused (`access denied`), the Vault VM's succeeds and can write. **This is the check that matters** — a snapshot share readable by the cluster would hand every secret to anything that could schedule a pod.

- [x] **Step 6: Report back** so the plan for PRs 3-5 can be written against what actually exists.
