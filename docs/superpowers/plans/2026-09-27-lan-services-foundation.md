# LAN Services Foundation Implementation Plan (PRs 1-3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five empty Debian 13 LXCs in `terraform/environments/shared`, then Pi-hole answering DNS for the LAN on `10.0.0.140`, then Traefik serving `*.hl.mgryn.cc` with a Let's Encrypt wildcard certificate on `10.0.0.141`.

**Architecture:** PR 1 teaches `modules/lxc` two inputs and makes its password optional, declares the five containers with one `for_each` module call, adds a `lan_services` inventory group and a playbook whose only play bootstraps Python. PR 2 adds a `pihole` role that seeds `pihole.toml`, runs the official installer unattended, and enforces settings with `pihole-FTL --config`. PR 3 adds a `traefik` role: pinned binary with checksum, systemd unit, static and dynamic config, ACME DNS-01 through Cloudflare. Gatus, LAN Orangutan and Glance (PRs 4-6) get their own plan once these three are applied.

**Tech Stack:** Terraform 1.16 + `telmate/proxmox` 3.0.2-rc10; Ansible core 2.21 (ansible-lint production profile), `ansible.builtin`; Pi-hole v6 (core v6.4.3 installer, FTL v6.7.1 at time of writing); Traefik v3.7.13; Debian 13 (trixie) LXC template.

**Spec:** `docs/superpowers/specs/2026-09-27-lan-services-design.md` — sections "Terraform", "Ansible", "pihole", "traefik", "Secrets", "Rollout" steps 1-3, "Pull requests" 1-3.

## Global Constraints

- Branches: PR 1 on `lan-services` (exists, draft PR #51, carries the spec, this plan and the README diagram). PR 2 on `lan-pihole`, PR 3 on `lan-traefik`, each cut from `main` only after the previous PR is merged **and** its operator task has passed. Never commit to `main`, never merge, never push to `main`. An agent's job ends at an open PR.
- Commits: Conventional Commits, subject ≤ 50 chars, imperative, lowercase, no trailing period, body wrapped at 72. Types: `feat fix refactor docs chore ops`.
- **No `Co-Authored-By` trailer and no "generated with" line** in commits or PR bodies. CLAUDE.md overrides any default attribution.
- Addresses and vmids: `pihole` 140 / `10.0.0.140`, `traefik` 141 / `10.0.0.141`, `glance` 142 / `10.0.0.142`, `gatus` 143 / `10.0.0.143`, `orangutan` 144 / `10.0.0.144`. Gateway `10.0.0.1`.
- LXC resolvers: `nameserver = "10.0.0.1 1.1.1.1"` on all five. Never Pi-hole.
- Names: `*.hl.mgryn.cc`. Traefik's certificate: main `hl.mgryn.cc`, SAN `*.hl.mgryn.cc`.
- Secrets come from `ansible/secret.yaml` as top-level variables; each new one gets a placeholder in `ansible/secret.yaml.example`. Nothing secret in defaults, templates or git.
- Documentation lands with the change that makes it true: each PR updates `README.md`'s table and diagram (dashed `:::planned` → solid when it runs) and `docs/rebuild.md`.
- Never run a playbook against a real host, never `terraform plan`/`apply` against Proxmox, never read or decrypt `ansible/secret.yaml`. Rehearsals run only against local Docker containers.
- Tools: `ansible-lint`, `pre-commit`, `terraform`, `tflint` on PATH; `ansible-playbook`/`ansible-galaxy` at `B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin` (pipe output through `| cat`; Ansible refuses non-blocking stdio). `SCRATCH=/tmp/claude-1000/-home-ubuntu-homelab/a1d0cbc8-96e2-4958-aa39-2dfcd967e8a8/scratchpad`. Rehearsal files live in `$SCRATCH`, never in the repository.
- Terraform validation without touching the lock file: `TF_DATA_DIR=$SCRATCH/tfdata-<root> terraform -chdir=terraform/environments/<root> init -backend=false -input=false` then `validate`, then `git checkout -- terraform/environments/<root>/.terraform.lock.hcl`. A plain init adds linux hashes to the lock file; that change is never committed.
- Read narrowly: `grep -n`, `sed -n`, `head`/`tail`.

## Review Focus

- **A container the operator rebuilds** (Pi-hole LXC destroyed and recreated): the role must reach the same end state from nothing, including the admin password — Task 5's rehearsal runs the role twice on fresh containers, not only twice on one.
- **The password rotated in `secret.yaml`**: re-running the role must apply the new password, not skip because Pi-hole is already installed — Task 5 rehearses a rotation.
- **The Pi-hole installer being re-run on every play**: it must run only when Pi-hole is absent; a second play must report `changed=0` — Task 5 asserts it.
- **Traefik routes to a backend that is down or not yet built**: must answer 502 for that name only, never stop serving the others — Task 8 rehearses a route to an unreachable backend next to a working one.
- **The ACME token wrong or Cloudflare unreachable**: Traefik must still start and serve its default certificate, so a DNS-01 failure is a certificate problem, not an outage — Task 8 rehearses with a dummy token.

## File Map

| File | PR | Change | Responsibility |
| --- | --- | --- | --- |
| `terraform/modules/lxc/{variables,main}.tf` | 1 | modify | Optional password; `nameserver`, `searchdomain` |
| `terraform/environments/shared/main.tf` | 1 | modify | The five containers |
| `terraform/environments/shared/variables.tf` | 1 | modify | `lxc_ips`, `debian_lxc_template` |
| `terraform/environments/shared/shared.tfvars.example` | 1 | modify | Their documentation |
| `ansible/inventories/shared/hosts.yaml` | 1 | modify | `lan_services` group |
| `ansible/playbooks/lan_services.yaml` | 1, 2, 3 | create, extend | One play per service |
| `ansible/secret.yaml.example` | 1, 2, 3 | modify | `host_ips`, `proxmox_vm_ids`, new secrets |
| `ansible/roles/pihole/**` | 2 | create | Pi-hole v6 |
| `ansible/roles/traefik/**` | 3 | create | Traefik v3 |
| `README.md`, `docs/rebuild.md` | 1, 2, 3 | modify | What runs, how to rebuild it |
| `docs/superpowers/specs/2026-09-27-lan-services-design.md` | 1 | modify | Password decision |

**PR boundaries:** Tasks 1-3 are PR 1, Task 4 its operator run. Tasks 5-6 are PR 2, Task 7 its operator run. Tasks 8-9 are PR 3, Task 10 its operator run.

---

## PR 1 — five empty containers

### Task 1: LXC module inputs and the five containers

**Files:**
- Modify: `terraform/modules/lxc/variables.tf` (the `password` variable; append two variables)
- Modify: `terraform/modules/lxc/main.tf` (the resource block)
- Modify: `terraform/environments/shared/main.tf` (append)
- Modify: `terraform/environments/shared/variables.tf` (append)
- Modify: `terraform/environments/shared/shared.tfvars.example` (append)
- Modify: `docs/superpowers/specs/2026-09-27-lan-services-design.md` (the root-password paragraph)

**Interfaces:**
- Consumes: `var.ssh_public_key`, `var.gateway`, `var.pm_target_node` already declared in `environments/shared/variables.tf`.
- Produces: `module.lan_service["<name>"]` for `pihole traefik glance gatus orangutan`; variables `lxc_ips` (map of `"10.0.0.14x/24"`) and `debian_lxc_template` (string) that the operator sets in `shared.tfvars`.

- [x] **Step 1: Show the shared root has no LXCs yet**

Run: `grep -c 'modules/lxc' terraform/environments/shared/main.tf`
Expected: `0`

- [x] **Step 2: Make the module's password optional**

In `terraform/modules/lxc/variables.tf`, replace the `password` variable with:

```hcl
# Optional: with SSH keys injected, a container needs no root password, and
# leaving it null keeps one out of tfvars and state. prod's never-applied
# scaffolding still passes one.
variable "password" {
  description = "Root password for the LXC container; null for key-only access"
  type        = string
  sensitive   = true
  default     = null
}
```

Append to the same file:

```hcl
# DNS for the container itself. null inherits the Proxmox host's resolver,
# which is what every container got before these existed.
variable "nameserver" {
  description = "Space-separated DNS servers for the container"
  type        = string
  default     = null
}

variable "searchdomain" {
  description = "DNS search domain for the container"
  type        = string
  default     = null
}
```

In `terraform/modules/lxc/main.tf`, after `pool            = var.pool` add:

```hcl
  nameserver      = var.nameserver
  searchdomain    = var.searchdomain
```

- [x] **Step 3: Declare the shared root's inputs**

Append to `terraform/environments/shared/variables.tf`:

```hcl
# One address per LAN service, keyed by the names in local.lan_services
# in main.tf. Each must include the prefix length, e.g. "10.0.0.140/24".
variable "lxc_ips" {
  description = "Static address with prefix for each LAN service container"
  type        = map(string)

  validation {
    condition = alltrue([
      for name in ["pihole", "traefik", "glance", "gatus", "orangutan"] :
      can(regex("^10\\.0\\.0\\.[0-9]+/24$", lookup(var.lxc_ips, name, "")))
    ])
    error_message = "lxc_ips needs pihole, traefik, glance, gatus and orangutan, each as 10.0.0.N/24."
  }
}

# Must already be downloaded on the host: pveam update, then
# pveam download local <file>. See docs/rebuild.md.
variable "debian_lxc_template" {
  description = "Debian 13 LXC template, e.g. local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
  type        = string
}
```

- [x] **Step 4: Declare the containers**

Append to `terraform/environments/shared/main.tf`:

```hcl
################################################################################
# LAN services — one unprivileged LXC each
################################################################################

# vmid matches the address's last octet: pct enter 141 is Traefik.
# Pi-hole starts first, ahead of vault-02 (order=5) and nfs-01 (order=10):
# after a host power loss every other machine's lookups go through it.
locals {
  lan_services = {
    pihole    = { vmid = 140, memory = 256, rootfs_size = "8G", startup = "order=1" }
    traefik   = { vmid = 141, memory = 256, rootfs_size = "4G", startup = "order=2" }
    glance    = { vmid = 142, memory = 128, rootfs_size = "4G", startup = "order=15" }
    gatus     = { vmid = 143, memory = 128, rootfs_size = "4G", startup = "order=15" }
    orangutan = { vmid = 144, memory = 256, rootfs_size = "4G", startup = "order=15" }
  }
}

module "lan_service" {
  source   = "../../modules/lxc"
  for_each = local.lan_services

  vmid               = each.value.vmid
  target_node        = var.pm_target_node
  hostname           = each.key
  ostemplate         = var.debian_lxc_template
  ssh_public_keys    = var.ssh_public_key
  unprivileged       = true
  start_at_node_boot = true
  pool               = "LXC"

  cores  = 1
  memory = each.value.memory
  swap   = 0

  rootfs_storage = "local-lvm"
  rootfs_size    = each.value.rootfs_size

  network_bridge = "vmbr0"
  network_ip     = var.lxc_ips[each.key]
  network_gw     = var.gateway

  # Never Pi-hole: Gatus alerts and Traefik's certificate renewals must
  # keep resolving when Pi-hole is the thing that is down.
  nameserver = "10.0.0.1 1.1.1.1"

  # systemd in Debian 13 needs nesting inside an unprivileged container.
  features_enabled = true
  features = {
    nesting = true
  }

  startup = each.value.startup
  tags    = "lxc,shared,${each.key}"
}
```

- [x] **Step 5: Document the new tfvars**

Append to `terraform/environments/shared/shared.tfvars.example`:

```hcl

# LAN services (docs/superpowers/specs/2026-09-27-lan-services-design.md).
# The template must already be on the host:
#   pveam update && pveam available | grep debian-13
#   pveam download local debian-13-standard_<version>_amd64.tar.zst
debian_lxc_template = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"

# Outside the router's DHCP pool (.2-.99). vmids in main.tf match the last
# octet.
lxc_ips = {
  pihole    = "10.0.0.140/24"
  traefik   = "10.0.0.141/24"
  glance    = "10.0.0.142/24"
  gatus     = "10.0.0.143/24"
  orangutan = "10.0.0.144/24"
}
```

- [x] **Step 6: Record the password decision in the spec**

In `docs/superpowers/specs/2026-09-27-lan-services-design.md`, replace the paragraph beginning "The root password is a `random_password` resource" with:

```markdown
No root password: `modules/lxc`'s `password` input becomes optional, and
these containers leave it null. Access is the injected SSH key alone, and
no password lands in tfvars or state.
```

Replace "`modules/lxc` gains `nameserver` and `searchdomain` inputs" paragraph's first sentence to read "`modules/lxc` gains `nameserver` and `searchdomain` inputs and an optional `password`,".

- [x] **Step 7: Validate both roots that use the module**

```bash
cd /home/ubuntu/homelab
terraform fmt -check -recursive terraform/
for env in shared dev; do
  TF_DATA_DIR=$SCRATCH/tfdata-$env terraform -chdir=terraform/environments/$env init -backend=false -input=false >/dev/null
  terraform -chdir=terraform/environments/$env validate -no-color
  git checkout -- terraform/environments/$env/.terraform.lock.hcl
done
tflint --chdir=terraform/environments/shared --config="$PWD/.tflint.hcl"
git status --short
```

Expected: `fmt` silent; `Success! The configuration is valid.` twice; `tflint` silent; `git status` lists only the six files above.

- [x] **Step 8: Show the validation catches a bad address**

```bash
cd $SCRATCH && rm -rf tfv && mkdir tfv && cp -r /home/ubuntu/homelab/terraform tfv/
cd tfv/terraform/environments/shared
TF_DATA_DIR=$SCRATCH/tfdata-shared terraform init -backend=false -input=false >/dev/null
terraform console -var='lxc_ips={pihole="10.0.0.140"}' -var='debian_lxc_template=x' \
  -var='pm_api_url=x' -var='pm_api_token_id=x' -var='pm_api_token_secret=x' \
  -var='ci_password=x' -var='ssh_public_key=x' -var='nfs_vm_ip=x' -var='vault_vm_ip=x' <<< 'var.lxc_ips' 2>&1 | grep -m1 'lxc_ips needs'
```

Expected: `lxc_ips needs pihole, traefik, glance, gatus and orangutan, each as 10.0.0.N/24.` If `console` asks for another variable, add it as `-var='<name>=x'`.

- [x] **Step 9: Commit**

```bash
cd /home/ubuntu/homelab
git add terraform/modules/lxc terraform/environments/shared docs/superpowers/specs/2026-09-27-lan-services-design.md
git commit -m "feat: add the lan service containers" -m "Five unprivileged Debian 13 LXCs in the shared root, vmids 140-144 at
the matching addresses, resolving through the router and 1.1.1.1 rather
than Pi-hole. modules/lxc gains nameserver and searchdomain inputs and
an optional password; these containers have none, SSH key only."
```

### Task 2: Inventory and the bootstrap playbook

**Files:**
- Modify: `ansible/inventories/shared/hosts.yaml` (append a group under `children`)
- Create: `ansible/playbooks/lan_services.yaml`
- Modify: `ansible/secret.yaml.example` (`host_ips`, `proxmox_vm_ids`)

**Interfaces:**
- Consumes: `host_ips`, `proxmox_vm_ids`, `ssh_private_key` from `secret.yaml`.
- Produces: groups `lan_services` with children `pihole`, `traefik`, `glance`, `gatus`, `orangutan`, one host each of the same name; playbook `ansible/playbooks/lan_services.yaml` whose first play bootstraps Python on `lan_services`. PR 2 and PR 3 append plays to it. `host_ips['pve']` for PR 3.

- [x] **Step 1: Show the group does not exist**

Run: `grep -c lan_services ansible/inventories/shared/hosts.yaml`
Expected: `0`

- [x] **Step 2: Add the group**

Append under `all.children` in `ansible/inventories/shared/hosts.yaml`, at the same indentation as `vault:`:

```yaml
    # One unprivileged LXC per LAN service. Containers have no cloud-init
    # user: Terraform injects the key for root, there is no sudo in the
    # Debian template, and become would only fail looking for it.
    lan_services:
      vars:
        ansible_user: root
        ansible_become: false
      children:
        pihole:
          hosts:
            pihole:
              ansible_host: "{{ host_ips['pihole'] }}"
              proxmox_vm_id: "{{ proxmox_vm_ids['pihole'] }}"
        traefik:
          hosts:
            traefik:
              ansible_host: "{{ host_ips['traefik'] }}"
              proxmox_vm_id: "{{ proxmox_vm_ids['traefik'] }}"
        glance:
          hosts:
            glance:
              ansible_host: "{{ host_ips['glance'] }}"
              proxmox_vm_id: "{{ proxmox_vm_ids['glance'] }}"
        gatus:
          hosts:
            gatus:
              ansible_host: "{{ host_ips['gatus'] }}"
              proxmox_vm_id: "{{ proxmox_vm_ids['gatus'] }}"
        orangutan:
          hosts:
            orangutan:
              ansible_host: "{{ host_ips['orangutan'] }}"
              proxmox_vm_id: "{{ proxmox_vm_ids['orangutan'] }}"
```

- [x] **Step 3: Create the playbook**

`ansible/playbooks/lan_services.yaml`:

```yaml
---
# LAN services, one LXC each, in dependency order. Run from ansible/:
#   ansible-playbook -i inventories/shared playbooks/lan_services.yaml \
#     -e @secret.yaml --ask-vault-pass
# --limit <service> runs one; the bootstrap play always applies to it.

- name: Bootstrap Python on the LAN service containers
  hosts: lan_services
  gather_facts: false
  tasks:
    # The Debian LXC template may ship without python3, which every module
    # but raw needs.
    - name: Install python3 when absent
      ansible.builtin.raw: >-
        test -x /usr/bin/python3 && echo present ||
        (apt-get update -qq && apt-get install -y -qq python3 >/dev/null && echo installed)
      register: lan_services_python
      changed_when: "'installed' in lan_services_python.stdout"
```

- [x] **Step 4: Add the example addresses**

In `ansible/secret.yaml.example`, append to `host_ips:` after `vault-02: 10.0.0.133`:

```yaml
  pihole: 10.0.0.140
  traefik: 10.0.0.141
  glance: 10.0.0.142
  gatus: 10.0.0.143
  orangutan: 10.0.0.144
  # The Proxmox host itself, for Traefik's proxmox.hl.mgryn.cc route and
  # Gatus's check of the UI on :8006.
  pve: 10.0.0.<N>
```

and to `proxmox_vm_ids:` after `vault-02: 105`:

```yaml
  pihole: 140
  traefik: 141
  glance: 142
  gatus: 143
  orangutan: 144
```

- [x] **Step 5: Check the inventory resolves and the playbook lints**

```bash
cd /home/ubuntu/homelab/ansible
cat > $SCRATCH/inv-vars.yaml <<'EOF'
host_ips: {nfs-01: 10.0.0.131, vault-02: 10.0.0.133, pihole: 10.0.0.140, traefik: 10.0.0.141, glance: 10.0.0.142, gatus: 10.0.0.143, orangutan: 10.0.0.144}
proxmox_vm_ids: {nfs-01: 103, vault-02: 105, pihole: 140, traefik: 141, glance: 142, gatus: 143, orangutan: 144}
user_name: ubuntu
ssh_private_key: ~/.ssh/none
EOF
$B/ansible-inventory -i inventories/shared -e @$SCRATCH/inv-vars.yaml --host traefik 2>&1 | cat
$B/ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @$SCRATCH/inv-vars.yaml --list-hosts 2>&1 | cat
ansible-lint playbooks/lan_services.yaml
```

Expected: the host dump shows `"ansible_user": "root"`, `"ansible_become": false`, `"ansible_host": "10.0.0.141"`; `--list-hosts` lists the five hosts; ansible-lint `Passed`.

- [x] **Step 6: Rehearse the bootstrap play against a bare Debian 13 container**

```bash
$B/ansible-galaxy collection install community.docker -p $SCRATCH/collections 2>&1 | tail -1
docker rm -f lan-bootstrap 2>/dev/null
docker run -d --name lan-bootstrap debian:trixie sleep infinity
cat > $SCRATCH/rehearse-bootstrap.ini <<'EOF'
[pihole]
pihole ansible_connection=community.docker.docker ansible_host=lan-bootstrap
[lan_services:children]
pihole
[lan_services:vars]
ansible_become=false
EOF
cd /home/ubuntu/homelab/ansible
for run in 1 2; do
  ANSIBLE_COLLECTIONS_PATH=$SCRATCH/collections:$HOME/.ansible/collections \
    $B/ansible-playbook -i $SCRATCH/rehearse-bootstrap.ini playbooks/lan_services.yaml 2>&1 | grep -E 'changed=|failed=' | cat
done
docker rm -f lan-bootstrap
```

Expected: run 1 `changed=1 ... failed=0`; run 2 `changed=0 ... failed=0`.

- [x] **Step 7: Commit**

```bash
cd /home/ubuntu/homelab
git add ansible/inventories/shared/hosts.yaml ansible/playbooks/lan_services.yaml ansible/secret.yaml.example
git commit -m "feat: add the lan services inventory" -m "A lan_services group in the shared inventory, one child group per
container, connecting as root without become. lan_services.yaml starts
with a play that installs python3 where the template lacks it; each
service's play is appended as its role lands."
```

### Task 3: PR 1 documentation

**Files:**
- Modify: `README.md` (the "What actually runs" table)
- Modify: `docs/rebuild.md` (steps 2 and 4; a new last step)

**Interfaces:**
- Consumes: Task 1's tfvars names, Task 2's playbook path.
- Produces: rebuild step "LAN services" that PRs 2 and 3 extend.

- [x] **Step 1: README table row**

In `README.md`, after the `vault-02` row add:

```markdown
| LXCs       | `pihole`, `traefik`, `glance`, `gatus`, `orangutan` at `.140`–`.144`, empty until their roles land | `terraform/environments/shared` |
```

- [x] **Step 2: rebuild.md step 2**

In `docs/rebuild.md` step 2, replace "(the `LXC` pool is unused by dev today; only prod's never-applied scaffolding would need it, and its Debian template, should prod ever apply)" with "(the `LXC` pool holds the LAN service containers; grant `TerraformProv` on `/pool/LXC` as on the others, or placement fails)", and append to step 2:

```markdown
   Download the Debian 13 LXC template the LAN services use, and put its
   name in `shared.tfvars` as `debian_lxc_template`:
   `pveam update && pveam available | grep debian-13`, then
   `pveam download local <file>`.
```

- [x] **Step 3: rebuild.md step 4**

In step 4, change "and `vault-02` (vmid 105) with its data disk;" to "`vault-02` (vmid 105) with its data disk, and the five LAN service containers (vmids 140–144);".

- [x] **Step 4: rebuild.md new last step**

After the last numbered step of "Rebuild order" (the `/etc/hosts` step), add:

```markdown
15. **LAN services** — from `ansible/`:

    ```bash
    ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass
    ```

    Each service's play is added as its role lands; see the
    [LAN services design](superpowers/specs/2026-09-27-lan-services-design.md).
```

- [x] **Step 5: Check**

Run: `pre-commit run --all-files 2>&1 | grep -iv 'passed\|skipped'; grep -n '^1[0-9]\. \*\*' docs/rebuild.md`
Expected: no failures; steps 10–15 listed once each.

- [x] **Step 6: Commit**

```bash
git add README.md docs/rebuild.md
git commit -m "docs: document the lan service containers" -m "The README lists the five containers as existing but empty. rebuild.md
grants TerraformProv on the LXC pool, downloads the Debian template,
and ends with the lan_services playbook."
```

### Task 4: Operator — create the containers (owner, not an agent)

- [x] On `pve`: `pveam update && pveam available | grep debian-13`, then `pveam download local <file>`.
- [x] On `pve`: the `LXC` pool exists (`pveum pool list`), and `pveum acl modify /pool/LXC --roles TerraformProv --users terraform@pve` (or the token's user) has been run.
- [x] In `shared.tfvars` on the Mac: `debian_lxc_template` and `lxc_ips` as in `shared.tfvars.example`.
- [x] `terraform plan -var-file=shared.tfvars` in `environments/shared`: **5 to add, 0 to change, 0 to destroy.** Anything else is a stop.
- [x] `terraform apply -var-file=shared.tfvars`.
- [x] `terraform plan -var-file=shared.tfvars` again: **No changes.** An in-place update on the new containers (e.g. tags reordered by Proxmox) is drift to fix in code before merging, not noise to skim.
- [x] `ansible-vault edit ansible/secret.yaml`: add the `host_ips` and `proxmox_vm_ids` entries from the example, including `pve`.
- [x] `ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass`: five hosts `ok`, `failed=0`.
- [x] `ssh -i ~/.ssh/homelab_dev root@10.0.0.140 cat /etc/resolv.conf` shows `nameserver 10.0.0.1` and `nameserver 1.1.1.1`.
- [x] Mark PR 1 ready (`gh pr ready 51`); the owner merges.

---

## PR 2 — Pi-hole

### Task 5: The pihole role

**Files:**
- Create: `ansible/roles/pihole/defaults/main.yaml`
- Create: `ansible/roles/pihole/tasks/main.yaml`
- Create: `ansible/roles/pihole/tasks/ftl_setting.yaml`
- Create: `ansible/roles/pihole/templates/pihole.toml.j2`
- Create: `ansible/roles/pihole/templates/adlists.list.j2`
- Create: `ansible/roles/pihole/handlers/main.yaml`
- Create: `ansible/roles/pihole/meta/main.yaml`
- Modify: `ansible/playbooks/lan_services.yaml` (append a play)
- Modify: `ansible/secret.yaml.example` (append `pihole_admin_password`)

**Interfaces:**
- Consumes: group `pihole` and the bootstrap play (Task 2); `pihole_admin_password` from `secret.yaml`.
- Produces: Pi-hole answering DNS on `:53` for the LAN and its web UI on `:80` at `/admin/`, for PR 3's route. Settings `pihole_upstreams`, `pihole_listening_mode`, `pihole_rev_server`, `pihole_adlists`.

- [x] **Step 1: Stand up a systemd Debian 13 container and write the rehearsal inventory**

```bash
cat > $SCRATCH/lan-container.sh <<'EOF'
#!/bin/sh
# usage: lan-container.sh <name> -- a Debian 13 container running systemd
docker rm -f "$1" >/dev/null 2>&1
docker run -d --name "$1" --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  debian:trixie bash -c 'apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus >/dev/null && exec /lib/systemd/systemd' >/dev/null
for i in $(seq 60); do
  s=$(docker exec "$1" systemctl is-system-running 2>/dev/null)
  case "$s" in running|degraded) echo "$1: $s"; exit 0;; esac
  sleep 2
done
echo "$1: systemd did not come up"; exit 1
EOF
chmod +x $SCRATCH/lan-container.sh
$SCRATCH/lan-container.sh lan-pihole
cat > $SCRATCH/rehearse-pihole.ini <<'EOF'
[pihole]
pihole ansible_connection=community.docker.docker ansible_host=lan-pihole
[lan_services:children]
pihole
[lan_services:vars]
ansible_become=false
EOF
printf 'pihole_admin_password: "first-password-123"\n' > $SCRATCH/pihole-secrets.yaml
cat > $SCRATCH/run-pihole.sh <<'EOF'
#!/bin/sh
cd /home/ubuntu/homelab/ansible
ANSIBLE_COLLECTIONS_PATH=$SCRATCH/collections:$HOME/.ansible/collections \
  $B/ansible-playbook -i $SCRATCH/rehearse-pihole.ini playbooks/lan_services.yaml \
  -e @$SCRATCH/pihole-secrets.yaml --limit pihole "$@" 2>&1 | cat
EOF
chmod +x $SCRATCH/run-pihole.sh
```

Expected: `lan-pihole: running` (or `degraded`).

- [x] **Step 2: Write the checks, and see them fail**

```bash
cat > $SCRATCH/check-pihole.sh <<'EOF'
#!/bin/sh
# Passes only when Pi-hole answers, blocks, and holds the expected settings.
C=${1:-lan-pihole}
docker exec $C sh -c 'command -v dig >/dev/null || (apt-get install -y -qq dnsutils >/dev/null)'
fail=0
r=$(docker exec $C dig @127.0.0.1 example.com +short | head -1)
[ -n "$r" ] && echo "ok resolve example.com -> $r" || { echo "FAIL resolve"; fail=1; }
d=$(docker exec $C pihole-FTL sqlite3 /etc/pihole/gravity.db "select domain from gravity limit 1" 2>/dev/null)
b=$(docker exec $C dig @127.0.0.1 "$d" +short | head -1)
[ "$b" = "0.0.0.0" ] && echo "ok block $d" || { echo "FAIL block '$d' -> '$b'"; fail=1; }
for kv in "dns.listeningMode=ALL" "dns.upstreams=1.1.1.1" "dns.revServers=10.0.0.1"; do
  k=${kv%%=*}; v=${kv#*=}
  docker exec $C pihole-FTL --config "$k" | grep -q "$v" && echo "ok $k" || { echo "FAIL $k"; fail=1; }
done
n=$(docker exec $C pihole-FTL sqlite3 /etc/pihole/gravity.db "select count(*) from adlist where address like '%StevenBlack%'" 2>/dev/null)
[ "$n" = "1" ] && echo "ok adlist" || { echo "FAIL adlist count '$n'"; fail=1; }
docker exec $C systemctl is-enabled pihole-FTL >/dev/null && echo "ok enabled" || { echo "FAIL enabled"; fail=1; }
exit $fail
EOF
chmod +x $SCRATCH/check-pihole.sh
$SCRATCH/check-pihole.sh; echo "exit=$?"
```

Expected: `FAIL` lines and `exit=1` — nothing is installed.

- [x] **Step 3: Role metadata and defaults**

`ansible/roles/pihole/meta/main.yaml`:

```yaml
---
galaxy_info:
  author: homelab
  description: Pi-hole v6 for LAN DNS and ad blocking
  license: MIT
  min_ansible_version: "2.17"
  platforms:
    - name: Debian
      versions:
        - trixie
dependencies: []
```

`ansible/roles/pihole/defaults/main.yaml`:

```yaml
---
# The installer at a fixed tag, so its behaviour does not change under us.
# It still installs the current Pi-hole and FTL releases: Pi-hole offers no
# way to pin those. Upgrade by hand with `pihole -up`.
pihole_installer_url: "https://raw.githubusercontent.com/pi-hole/pi-hole/v6.4.3/automated%20install/basic-install.sh"

pihole_upstreams:
  - 1.1.1.1
  - 9.9.9.9

# ALL: answer every client, not only those on a directly attached subnet.
# The LAN is one /24, but the extender in the path makes "local" guessing
# pointless; the container is not reachable from outside the LAN anyway.
pihole_listening_mode: ALL

# Reverse lookups for the LAN go to the router, so the query log shows
# device names instead of bare addresses. Format: enabled,cidr,server,domain.
pihole_rev_server: "true,10.0.0.0/24,10.0.0.1,lan"

pihole_adlists:
  - https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts

# Where the role records a hash of the admin password it last set, so a
# rotation in secret.yaml is applied and an unchanged one is not.
pihole_password_marker: /etc/pihole/.ansible-admin-password.sha256
```

- [x] **Step 4: Seed templates**

`ansible/roles/pihole/templates/pihole.toml.j2` — read by the installer, which runs unattended only when this file exists; FTL rewrites it in full on first start, after which `tasks/ftl_setting.yaml` owns these keys:

```jinja
# Seeded by Ansible before the Pi-hole installer runs. FTL rewrites this
# file on first start; afterwards the role sets these keys through
# pihole-FTL --config.
[dns]
  upstreams = [{% for u in pihole_upstreams %}"{{ u }}"{{ ", " if not loop.last }}{% endfor %}]
  listeningMode = "{{ pihole_listening_mode }}"
  revServers = ["{{ pihole_rev_server }}"]
```

`ansible/roles/pihole/templates/adlists.list.j2`:

```jinja
{% for url in pihole_adlists %}
{{ url }}
{% endfor %}
```

- [x] **Step 5: One FTL setting, idempotently**

`ansible/roles/pihole/tasks/ftl_setting.yaml` — reads the value, sets it, reads it again; `changed` only when the two reads differ, so the comparison never depends on how FTL formats a value:

```yaml
---
- name: Read {{ pihole_setting.key }}
  ansible.builtin.command: pihole-FTL --config {{ pihole_setting.key }}
  register: pihole_setting_before
  changed_when: false

- name: Set {{ pihole_setting.key }}
  ansible.builtin.command: pihole-FTL --config {{ pihole_setting.key }} {{ pihole_setting.value | quote }}
  register: pihole_setting_set
  changed_when: false
  when: not ansible_check_mode

- name: Re-read {{ pihole_setting.key }}
  ansible.builtin.command: pihole-FTL --config {{ pihole_setting.key }}
  register: pihole_setting_after
  changed_when: pihole_setting_after.stdout != pihole_setting_before.stdout
```

- [x] **Step 6: Main tasks and handler**

`ansible/roles/pihole/tasks/main.yaml`:

```yaml
---
- name: Require the Pi-hole admin password
  ansible.builtin.assert:
    that:
      - pihole_admin_password is defined
      - pihole_admin_password | length >= 12
    fail_msg: pihole_admin_password must be set in ansible/secret.yaml, 12 characters or more.
    quiet: true

- name: Install the installer's prerequisites
  ansible.builtin.apt:
    name: [curl, ca-certificates]
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Create /etc/pihole
  ansible.builtin.file:
    path: /etc/pihole
    state: directory
    mode: "0755"

- name: Seed pihole.toml so the installer runs unattended
  ansible.builtin.template:
    src: pihole.toml.j2
    dest: /etc/pihole/pihole.toml
    mode: "0644"
    force: false

- name: Seed the blocklists gravity starts from
  ansible.builtin.template:
    src: adlists.list.j2
    dest: /etc/pihole/adlists.list
    mode: "0644"
    force: false

- name: Install Pi-hole
  ansible.builtin.shell:
    cmd: set -o pipefail && curl -fsSL {{ pihole_installer_url | quote }} | bash /dev/stdin --unattended
    executable: /bin/bash
    creates: /usr/local/bin/pihole

- name: Apply FTL settings
  ansible.builtin.include_tasks: ftl_setting.yaml
  loop:
    - { key: dns.upstreams, value: "{{ pihole_upstreams | to_json }}" }
    - { key: dns.listeningMode, value: "{{ pihole_listening_mode }}" }
    - { key: dns.revServers, value: "{{ [pihole_rev_server] | to_json }}" }
  loop_control:
    loop_var: pihole_setting
    label: "{{ pihole_setting.key }}"

- name: Read the hash of the password last set
  ansible.builtin.slurp:
    src: "{{ pihole_password_marker }}"
  register: pihole_password_marker_content
  failed_when: false

- name: Set the admin password
  ansible.builtin.command:
    argv: [pihole, setpassword, "{{ pihole_admin_password }}"]
  when: >-
    (pihole_password_marker_content.content | default('') | b64decode | trim)
    != (pihole_admin_password | hash('sha256'))
  changed_when: true
  no_log: true

- name: Record the hash of the password now set
  ansible.builtin.copy:
    content: "{{ pihole_admin_password | hash('sha256') }}\n"
    dest: "{{ pihole_password_marker }}"
    mode: "0600"
  no_log: true

- name: Register each blocklist in gravity
  ansible.builtin.command:
    argv:
      - pihole-FTL
      - sqlite3
      - /etc/pihole/gravity.db
      - >-
        INSERT OR IGNORE INTO adlist (address, enabled, comment)
        VALUES ('{{ item }}', 1, 'ansible'); SELECT changes();
  loop: "{{ pihole_adlists }}"
  register: pihole_adlist_insert
  changed_when: pihole_adlist_insert.stdout | trim == '1'
  notify: Rebuild gravity

- name: Keep pihole-FTL running at boot
  ansible.builtin.service:
    name: pihole-FTL
    state: started
    enabled: true
```

`ansible/roles/pihole/handlers/main.yaml`:

```yaml
---
- name: Rebuild gravity
  ansible.builtin.command: pihole -g
  changed_when: true
```

- [x] **Step 7: Add the play and the example secret**

Append to `ansible/playbooks/lan_services.yaml`:

```yaml

- name: Pi-hole
  hosts: pihole
  roles:
    - pihole
```

Append to `ansible/secret.yaml.example`:

```yaml

# Pi-hole admin login at https://pihole.hl.mgryn.cc/admin/, 12+ characters.
# Changing it here and re-running playbooks/lan_services.yaml applies it.
pihole_admin_password: "<24 random chars>"
```

- [x] **Step 8: Rehearse — first run, checks, idempotence**

```bash
$SCRATCH/run-pihole.sh | grep -E 'changed=|failed=|FAILED|fatal'
$SCRATCH/check-pihole.sh; echo "exit=$?"
$SCRATCH/run-pihole.sh | grep -E 'changed=|failed='
```

Expected: first run `failed=0`; checks all `ok`, `exit=0`; second run `changed=0 ... failed=0`. If a check fails, fix the role, not the check, unless the check is shown wrong against Pi-hole's own documentation — say so in the report.

- [x] **Step 9: Rehearse — password rotation, and a login with it**

```bash
printf 'pihole_admin_password: "second-password-456"\n' > $SCRATCH/pihole-secrets.yaml
$SCRATCH/run-pihole.sh | grep -E 'Set the admin password|changed=|failed='
docker exec lan-pihole curl -s -X POST http://127.0.0.1/api/auth -d '{"password":"second-password-456"}' | grep -o '"valid":[a-z]*'
docker exec lan-pihole curl -s -X POST http://127.0.0.1/api/auth -d '{"password":"first-password-123"}' | grep -o '"valid":[a-z]*'
```

Expected: the task shows `changed`; the new password `"valid":true`; the old `"valid":false`.

- [x] **Step 10: Rehearse — a fresh container reaches the same state**

```bash
$SCRATCH/lan-container.sh lan-pihole
$SCRATCH/run-pihole.sh | grep -E 'changed=|failed='
$SCRATCH/check-pihole.sh; echo "exit=$?"
docker rm -f lan-pihole
```

Expected: `failed=0`, `exit=0`.

- [x] **Step 11: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/pihole playbooks/lan_services.yaml
cd .. && git add ansible/roles/pihole ansible/playbooks/lan_services.yaml ansible/secret.yaml.example
git commit -m "feat: add the pihole role" -m "Seeds pihole.toml and the blocklists, runs the official installer
unattended once, then holds upstreams, listening mode and reverse
lookups through pihole-FTL --config. The admin password is applied
when its hash differs from the last one set, so rotating it in
secret.yaml takes effect on the next run."
```

### Task 6: PR 2 documentation

**Files:**
- Modify: `README.md` (table row, diagram)
- Modify: `docs/rebuild.md` (step 15)

- [x] **Step 1: README**

In the table row added in Task 3, change "empty until their roles land" to "Pi-hole (DNS, ad blocking) at `.140`; the rest empty until their roles land". In the diagram, change `pihole["Pi-hole .140<br/>DNS + ad blocking"]:::planned` to `pihole["Pi-hole .140<br/>DNS + ad blocking"]`. Leave the `lan -. "DNS" .-> pihole` edge dashed: clients use it only after the cutover in PR 6.

- [x] **Step 2: rebuild.md step 15**

Append to step 15:

```markdown
    **Pi-hole** needs `pihole_admin_password` in `secret.yaml`. Check it
    from the workstation before pointing anything at it:
    `dig @10.0.0.140 example.com +short` answers, and a domain from its
    blocklist (`ssh root@10.0.0.140 pihole-FTL sqlite3 /etc/pihole/gravity.db
    "select domain from gravity limit 1"`) returns `0.0.0.0`.
```

- [x] **Step 3: Validate the diagram and commit**

```bash
cd $SCRATCH/mp 2>/dev/null || { mkdir -p $SCRATCH/mp && cd $SCRATCH/mp && npm init -y >/dev/null && npm i -s mermaid jsdom >/dev/null 2>&1; }
cat > p.mjs <<'EOF'
import { JSDOM } from 'jsdom'; import fs from 'fs';
const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window; globalThis.document = dom.window.document;
const { default: mermaid } = await import('mermaid');
const s = fs.readFileSync('/home/ubuntu/homelab/README.md','utf8');
const src = s.slice(s.indexOf('```mermaid') + 10, s.indexOf('```', s.indexOf('```mermaid') + 10));
try { await mermaid.parse(src); console.log('PARSE OK'); } catch (e) { console.log('PARSE FAIL', e.message); process.exit(1); }
EOF
node p.mjs
cd /home/ubuntu/homelab && pre-commit run --all-files 2>&1 | grep -iv 'passed\|skipped'
git add README.md docs/rebuild.md
git commit -m "docs: document pihole" -m "Pi-hole goes solid in the README diagram and gains its checks in
rebuild.md. Clients still resolve through the router until the cutover."
```

Expected: `PARSE OK`; no pre-commit failures.

### Task 7: Operator — Pi-hole (owner, not an agent)

- [x] `ansible-vault edit ansible/secret.yaml`: add `pihole_admin_password`.
- [x] Before running the playbook: `ssh -i ~/.ssh/homelab_dev root@10.0.0.140 'ss -lntup | grep -E ":(53|80)\b"'` prints nothing — nothing is already bound to the ports Pi-hole needs.
- [x] `ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass --limit pihole`: `failed=0`; a second run `changed=0`. FTL logging "Insufficient permissions to set system time (CAP_SYS_TIME)" is expected in an unprivileged LXC, not a failure.
- [x] From the Mac: `dig @10.0.0.140 example.com +short` answers; the blocklist domain from rebuild.md step 15 returns `0.0.0.0`.
- [x] `http://10.0.0.140/admin/` logs in with the password from `secret.yaml`.
- [x] Do **not** change the router's DNS yet — that is PR 6.

---

## PR 3 — Traefik

### Task 8: The traefik role

**Files:**
- Create: `ansible/roles/traefik/defaults/main.yaml`
- Create: `ansible/roles/traefik/tasks/main.yaml`
- Create: `ansible/roles/traefik/templates/traefik.yaml.j2`
- Create: `ansible/roles/traefik/templates/routes.yaml.j2`
- Create: `ansible/roles/traefik/templates/traefik.env.j2`
- Create: `ansible/roles/traefik/templates/traefik.service.j2`
- Create: `ansible/roles/traefik/handlers/main.yaml`
- Create: `ansible/roles/traefik/meta/main.yaml`
- Modify: `ansible/playbooks/lan_services.yaml` (append a play after Pi-hole's)
- Modify: `ansible/secret.yaml.example` (append two secrets)

**Interfaces:**
- Consumes: group `traefik` (Task 2); `host_ips['pve']`, `traefik_cloudflare_api_token`, `traefik_dashboard_users` from `secret.yaml`; Pi-hole on `http://10.0.0.140:80` (Task 5).
- Produces: `traefik_routes`, a list of `{name, host, url, insecure}` in role defaults. PRs 4-6 append their service's route to it. Entry points `web` (:80), `websecure` (:443), `metrics` (:8082); resolvers `letsencrypt`, `letsencrypt-staging`, chosen by `traefik_cert_resolver`.

- [ ] **Step 1: Container and checks, failing first**

```bash
$SCRATCH/lan-container.sh lan-traefik
docker exec lan-traefik sh -c 'apt-get install -y -qq curl >/dev/null'
cat > $SCRATCH/rehearse-traefik.ini <<'EOF'
[traefik]
traefik ansible_connection=community.docker.docker ansible_host=lan-traefik
[lan_services:children]
traefik
[lan_services:vars]
ansible_become=false
EOF
# htpasswd line for admin / rehearsal-pass (bcrypt; generated here, not a real secret)
H=$(docker exec lan-traefik sh -c 'apt-get install -y -qq apache2-utils >/dev/null && htpasswd -nbB admin rehearsal-pass')
cat > $SCRATCH/traefik-secrets.yaml <<EOF
host_ips: {pve: 192.0.2.10, pihole: 127.0.0.1}
traefik_cloudflare_api_token: "dummy-token-for-rehearsal"
traefik_dashboard_users: ["$H"]
EOF
cat > $SCRATCH/run-traefik.sh <<'EOF'
#!/bin/sh
cd /home/ubuntu/homelab/ansible
ANSIBLE_COLLECTIONS_PATH=$SCRATCH/collections:$HOME/.ansible/collections \
  $B/ansible-playbook -i $SCRATCH/rehearse-traefik.ini playbooks/lan_services.yaml \
  -e @$SCRATCH/traefik-secrets.yaml --limit traefik "$@" 2>&1 | cat
EOF
chmod +x $SCRATCH/run-traefik.sh
cat > $SCRATCH/check-traefik.sh <<'EOF'
#!/bin/sh
C=lan-traefik; fail=0
code() { docker exec $C curl -sk -o /dev/null -w '%{http_code}' --resolve "$1:$2:127.0.0.1" "$3" $4; }
[ "$(code pihole.hl.mgryn.cc 80 http://pihole.hl.mgryn.cc/)" = "308" ] && echo "ok http redirects" || { echo "FAIL redirect"; fail=1; }
[ "$(code traefik.hl.mgryn.cc 443 https://traefik.hl.mgryn.cc/dashboard/)" = "401" ] && echo "ok dashboard needs auth" || { echo "FAIL dashboard auth"; fail=1; }
[ "$(code traefik.hl.mgryn.cc 443 https://traefik.hl.mgryn.cc/dashboard/ '-u admin:rehearsal-pass')" = "200" ] && echo "ok dashboard login" || { echo "FAIL dashboard login"; fail=1; }
c=$(code proxmox.hl.mgryn.cc 443 https://proxmox.hl.mgryn.cc/)
[ "$c" = "502" ] || [ "$c" = "504" ] && echo "ok unreachable backend -> $c" || { echo "FAIL proxmox route -> $c"; fail=1; }
docker exec $C curl -s http://127.0.0.1:8082/metrics | grep -q '^traefik_' && echo "ok metrics" || { echo "FAIL metrics"; fail=1; }
docker exec $C sh -c 'stat -c "%a %U" /etc/traefik/traefik.env' | grep -q '^600 root$' && echo "ok env file 0600" || { echo "FAIL env file mode"; fail=1; }
docker exec $C sh -c 'stat -c %U /proc/$(systemctl show -p MainPID --value traefik)' | grep -q '^traefik$' && echo "ok runs as traefik" || { echo "FAIL user"; fail=1; }
docker exec $C systemctl is-enabled traefik >/dev/null && echo "ok enabled" || { echo "FAIL enabled"; fail=1; }
exit $fail
EOF
chmod +x $SCRATCH/check-traefik.sh
$SCRATCH/check-traefik.sh; echo "exit=$?"
```

Expected: `FAIL` lines, `exit=1`.

The Pi-hole backend in the rehearsal is `127.0.0.1:80`, where nothing listens, so `pihole.hl` itself would also 502 — the redirect check uses plain HTTP, which Traefik answers before routing.

- [ ] **Step 2: Metadata and defaults**

`ansible/roles/traefik/meta/main.yaml`:

```yaml
---
galaxy_info:
  author: homelab
  description: Traefik v3 as the LAN's edge proxy for *.hl.mgryn.cc
  license: MIT
  min_ansible_version: "2.17"
  platforms:
    - name: Debian
      versions:
        - trixie
dependencies: []
```

`ansible/roles/traefik/defaults/main.yaml`:

```yaml
---
traefik_version: "3.7.13"
traefik_release_url: "https://github.com/traefik/traefik/releases/download/v{{ traefik_version }}"
traefik_archive: "traefik_v{{ traefik_version }}_linux_amd64.tar.gz"

traefik_domain: hl.mgryn.cc

# letsencrypt-staging while debugging an issuance: production allows five
# failed validations per hostname per hour. Switch with
#   -e traefik_cert_resolver=letsencrypt-staging
traefik_cert_resolver: letsencrypt

# Every name Traefik serves apart from its own dashboard. Each later role's
# PR appends its entry. insecure: skip verifying the backend's certificate,
# for Proxmox's self-signed one.
traefik_routes:
  - name: pihole
    host: "pihole.{{ traefik_domain }}"
    url: "http://{{ host_ips['pihole'] }}:80"
    insecure: false
  - name: proxmox
    host: "proxmox.{{ traefik_domain }}"
    url: "https://{{ host_ips['pve'] }}:8006"
    insecure: true
```

- [ ] **Step 3: Templates**

`ansible/roles/traefik/templates/traefik.yaml.j2`:

```jinja
# Managed by Ansible (roles/traefik). Static configuration: a change here
# restarts Traefik. Routes live in dynamic/, which it reloads on its own.
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: {{ traefik_cert_resolver }}
        domains:
          - main: "{{ traefik_domain }}"
            sans:
              - "*.{{ traefik_domain }}"
  metrics:
    address: ":8082"

certificatesResolvers:
  letsencrypt:
    acme:
      storage: /var/lib/traefik/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
  letsencrypt-staging:
    acme:
      caServer: https://acme-staging-v02.api.letsencrypt.org/directory
      storage: /var/lib/traefik/acme-staging.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

api:
  dashboard: true

metrics:
  prometheus:
    entryPoint: metrics

log:
  level: INFO
```

`ansible/roles/traefik/templates/routes.yaml.j2`:

```jinja
# Managed by Ansible (roles/traefik). Reloaded by Traefik on change.
http:
  routers:
    dashboard:
      rule: "Host(`traefik.{{ traefik_domain }}`)"
      entryPoints: [websecure]
      service: api@internal
      middlewares: [dashboard-auth]
{% for r in traefik_routes %}
    {{ r.name }}:
      rule: "Host(`{{ r.host }}`)"
      entryPoints: [websecure]
      service: {{ r.name }}
{% endfor %}

  services:
{% for r in traefik_routes %}
    {{ r.name }}:
      loadBalancer:
{% if r.insecure %}
        serversTransport: insecure
{% endif %}
        servers:
          - url: "{{ r.url }}"
{% endfor %}

  middlewares:
    dashboard-auth:
      basicAuth:
        users:
{% for u in traefik_dashboard_users %}
          - "{{ u }}"
{% endfor %}

  serversTransports:
    insecure:
      insecureSkipVerify: true
```

`ansible/roles/traefik/templates/traefik.env.j2`:

```jinja
# Managed by Ansible. Read by systemd as root; mode 0600.
CF_DNS_API_TOKEN={{ traefik_cloudflare_api_token }}
```

`ansible/roles/traefik/templates/traefik.service.j2`:

```jinja
# Managed by Ansible (roles/traefik).
[Unit]
Description=Traefik edge proxy
After=network-online.target
Wants=network-online.target

[Service]
User=traefik
Group=traefik
EnvironmentFile=/etc/traefik/traefik.env
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yaml
# Ports 80 and 443 without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Tasks and handlers**

`ansible/roles/traefik/tasks/main.yaml`:

```yaml
---
- name: Require Traefik's secrets
  ansible.builtin.assert:
    that:
      - traefik_cloudflare_api_token is defined
      - traefik_cloudflare_api_token | length > 0
      - traefik_dashboard_users is defined
      - traefik_dashboard_users | length > 0
      - host_ips['pve'] is defined
    fail_msg: >-
      traefik_cloudflare_api_token, traefik_dashboard_users and host_ips['pve']
      must be set in ansible/secret.yaml.
    quiet: true

- name: Create the traefik system user
  ansible.builtin.user:
    name: traefik
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/traefik
    create_home: false

- name: Create Traefik's directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: traefik
    mode: "{{ item.mode }}"
  loop:
    - { path: /etc/traefik, owner: root, mode: "0750" }
    - { path: /etc/traefik/dynamic, owner: root, mode: "0750" }
    - { path: /var/lib/traefik, owner: traefik, mode: "0700" }
    - { path: "/opt/traefik/{{ traefik_version }}", owner: root, mode: "0755" }

- name: Download Traefik, checked against the release's checksums
  ansible.builtin.get_url:
    url: "{{ traefik_release_url }}/{{ traefik_archive }}"
    dest: "/opt/traefik/{{ traefik_archive }}"
    checksum: "sha256:{{ traefik_release_url }}/traefik_v{{ traefik_version }}_checksums.txt"
    mode: "0644"

- name: Unpack Traefik
  ansible.builtin.unarchive:
    src: "/opt/traefik/{{ traefik_archive }}"
    dest: "/opt/traefik/{{ traefik_version }}"
    remote_src: true
    include: [traefik]
    creates: "/opt/traefik/{{ traefik_version }}/traefik"

- name: Point /usr/local/bin/traefik at this version
  ansible.builtin.file:
    src: "/opt/traefik/{{ traefik_version }}/traefik"
    dest: /usr/local/bin/traefik
    state: link
  notify: Restart traefik

- name: Write the static configuration
  ansible.builtin.template:
    src: traefik.yaml.j2
    dest: /etc/traefik/traefik.yaml
    owner: root
    group: traefik
    mode: "0640"
  notify: Restart traefik

- name: Write the Cloudflare token
  ansible.builtin.template:
    src: traefik.env.j2
    dest: /etc/traefik/traefik.env
    owner: root
    group: root
    mode: "0600"
  no_log: true
  notify: Restart traefik

- name: Write the routes
  ansible.builtin.template:
    src: routes.yaml.j2
    dest: /etc/traefik/dynamic/routes.yaml
    owner: root
    group: traefik
    mode: "0640"

- name: Install the systemd unit
  ansible.builtin.template:
    src: traefik.service.j2
    dest: /etc/systemd/system/traefik.service
    mode: "0644"
  notify: Restart traefik

- name: Start Traefik at boot
  ansible.builtin.systemd_service:
    name: traefik
    state: started
    enabled: true
    daemon_reload: true
```

`ansible/roles/traefik/handlers/main.yaml`:

```yaml
---
- name: Restart traefik
  ansible.builtin.systemd_service:
    name: traefik
    state: restarted
    daemon_reload: true
```

- [ ] **Step 5: Add the play and the example secrets**

Append to `ansible/playbooks/lan_services.yaml`:

```yaml

- name: Traefik
  hosts: traefik
  roles:
    - traefik
```

Append to `ansible/secret.yaml.example`:

```yaml

# Traefik's own Cloudflare token -- not cert-manager's, so each can be
# revoked alone. Same two permissions on the mgryn.cc zone:
#   Zone -> DNS  -> Edit   write the _acme-challenge TXT record
#   Zone -> Zone -> Read   look the zone up by name first
traefik_cloudflare_api_token: "<Cloudflare API token>"

# Dashboard logins at https://traefik.hl.mgryn.cc, htpasswd bcrypt lines:
#   htpasswd -nbB admin '<password>'
traefik_dashboard_users:
  - "admin:$2y$05$<bcrypt>"
```

- [ ] **Step 6: Rehearse — first run, checks, idempotence**

```bash
$SCRATCH/run-traefik.sh | grep -E 'changed=|failed=|FAILED|fatal'
sleep 3; $SCRATCH/check-traefik.sh; echo "exit=$?"
$SCRATCH/run-traefik.sh | grep -E 'changed=|failed='
docker exec lan-traefik journalctl -u traefik --no-pager | grep -m1 -i 'acme\|cloudflare'
```

Expected: first run `failed=0`; checks all `ok`, `exit=0`; second run `changed=0 ... failed=0`; the journal shows an ACME/Cloudflare error from the dummy token while Traefik keeps serving — the Review Focus case.

- [ ] **Step 7: Rehearse — a new route reloads without a restart**

```bash
PID1=$(docker exec lan-traefik systemctl show -p MainPID --value traefik)
$SCRATCH/run-traefik.sh -e '{"traefik_routes":[{"name":"extra","host":"extra.hl.mgryn.cc","url":"http://127.0.0.1:9","insecure":false}]}' | grep -E 'changed=|failed='
sleep 3
PID2=$(docker exec lan-traefik systemctl show -p MainPID --value traefik)
[ "$PID1" = "$PID2" ] && echo "ok no restart" || echo "FAIL restarted"
docker exec lan-traefik curl -sk -o /dev/null -w '%{http_code}\n' --resolve extra.hl.mgryn.cc:443:127.0.0.1 https://extra.hl.mgryn.cc/
docker rm -f lan-traefik
```

Expected: `ok no restart`; `502`.

- [ ] **Step 8: Lint and commit**

```bash
cd /home/ubuntu/homelab/ansible && ansible-lint roles/traefik playbooks/lan_services.yaml
cd .. && git add ansible/roles/traefik ansible/playbooks/lan_services.yaml ansible/secret.yaml.example
git commit -m "feat: add the traefik role" -m "Traefik v3 from the release archive, checked against its published
checksums, running as its own user with CAP_NET_BIND_SERVICE. A
wildcard certificate for *.hl.mgryn.cc by DNS-01 through its own
Cloudflare token, staging resolver alongside, routes to Pi-hole and
the Proxmox UI, and the dashboard behind basic auth."
```

### Task 9: PR 3 documentation

**Files:**
- Modify: `README.md` (table, diagram, the planned note)
- Modify: `docs/rebuild.md` (step 15)
- Modify: `CLAUDE.md` (the ingress bullet)

- [ ] **Step 1: README**

Table row from Task 3 becomes: "`pihole` (DNS, ad blocking) at `.140`, `traefik` (`*.hl.mgryn.cc`) at `.141`; the rest empty until their roles land". In the diagram, drop `:::planned` from `traefik[...]` and from `letsencrypt` if it carries it, and make `lan -. "*.hl.mgryn.cc" .-> traefik`, `traefik -.-> pihole` and `traefik -. "DNS-01" .-> letsencrypt` solid (`-->`, `-- "label" -->`). The Proxmox UI route needs no edge: the `pve` box already stands for the host.

In the "Planned, not yet running" paragraph, remove Pi-hole and Traefik from the list and add a sentence: "`pihole.hl.mgryn.cc`, `proxmox.hl.mgryn.cc` and `traefik.hl.mgryn.cc` resolve on any LAN device through a Cloudflare DNS-only wildcard record, `*.hl.mgryn.cc` → `10.0.0.141`."

- [ ] **Step 2: rebuild.md step 15**

Append:

```markdown
    **Traefik** needs `traefik_cloudflare_api_token` (its own token:
    Zone → DNS → Edit and Zone → Zone → Read on `mgryn.cc`) and
    `traefik_dashboard_users` in `secret.yaml`, and a DNS-only Cloudflare
    record `*.hl.mgryn.cc` → `10.0.0.141`. Issue from staging first
    (`-e traefik_cert_resolver=letsencrypt-staging`), then re-run without
    it; production allows five failed validations per hostname per hour.
    `curl -v https://pihole.hl.mgryn.cc/admin/` from the workstation then
    shows a Let's Encrypt certificate for `*.hl.mgryn.cc`.
```

- [ ] **Step 3: CLAUDE.md**

In the "Load-bearing and non-obvious" bullet that begins "**ingress-nginx is a DaemonSet on host ports 80/443**", append: "`*.hl.mgryn.cc` is the second exception: a DNS-only wildcard pointing at Traefik on `10.0.0.141`, which terminates TLS for the LAN services and the Proxmox UI."

- [ ] **Step 4: Validate and commit**

Run the Mermaid check from Task 6 Step 3 (`node $SCRATCH/mp/p.mjs`) and `pre-commit run --all-files`.

```bash
git add README.md docs/rebuild.md CLAUDE.md
git commit -m "docs: document traefik" -m "Traefik goes solid in the README diagram with its routes, rebuild.md
covers its token, the wildcard record and staging-first issuance, and
CLAUDE.md notes *.hl.mgryn.cc next to the other public names."
```

Expected: `PARSE OK`; no pre-commit failures.

### Task 10: Operator — Traefik (owner, not an agent)

- [ ] Cloudflare: create a token with Zone → DNS → Edit and Zone → Zone → Read on `mgryn.cc`.
- [ ] Cloudflare: DNS-only record `*.hl.mgryn.cc` → `10.0.0.141`. `dig +short pihole.hl.mgryn.cc` → `10.0.0.141`.
- [ ] `ansible-vault edit ansible/secret.yaml`: `traefik_cloudflare_api_token`, `traefik_dashboard_users` (`htpasswd -nbB admin '<password>'`).
- [ ] Staging: `ansible-playbook -i inventories/shared playbooks/lan_services.yaml -e @secret.yaml --ask-vault-pass --limit traefik -e traefik_cert_resolver=letsencrypt-staging`; `curl -vk https://pihole.hl.mgryn.cc/admin/ 2>&1 | grep -i 'issuer'` names a staging issuer.
- [ ] Production: the same without `-e traefik_cert_resolver=...`; `curl -v https://pihole.hl.mgryn.cc/admin/ 2>&1 | grep -iE 'issuer|subject|SSL certificate verify'` shows Let's Encrypt, `*.hl.mgryn.cc`, `verify ok`.
- [ ] `https://proxmox.hl.mgryn.cc` opens the Proxmox login; `https://traefik.hl.mgryn.cc/dashboard/` asks for the password and shows the three routers.
- [ ] Second playbook run: `changed=0`.
- [ ] PR 3 ready; the owner merges. Then: plan PRs 4-6 (Gatus, LAN Orangutan, Glance) against what is now live.
