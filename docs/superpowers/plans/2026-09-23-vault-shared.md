# Shared Vault Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `vault-01` (vmid 104) into `proxmox/environments/shared`, teach the `vault` role to configure any number of clusters, and namespace dev's KV paths under `secret/dev/` so a future prod cluster can share one Vault without either environment reading the other's secrets.

**Architecture:** Terraform adopts the running container into the shared root with an `import` block while dev releases it with `removed { destroy = false }`, exactly as `nfs-01` was moved. `roles/vault` gains a `vault_k8s_clusters` list; `k8s_auth.yaml` becomes a per-cluster task file included once per entry, and `seed.yaml` writes under a `vault_kv_prefix`. Dev's secrets are copied to the prefixed paths, the three manifests that name them are updated (two moving out of `base/` into the `dev/` overlay), the policy narrows to `secret/data/dev/*`, and only then are the old paths deleted.

**Tech Stack:** Terraform 1.16 + `telmate/proxmox` 3.0.2-rc10, tflint, Ansible (ansible-lint profile production), HashiCorp Vault (file storage, KV v2), argocd-vault-plugin, kustomize.

**Spec:** `docs/superpowers/specs/2026-09-23-vault-shared-design.md`

## Global Constraints

- Branch is `vault-shared` (exists, holds the spec commits). Never commit to `main`, never merge, never push to `main`. An agent's job ends at an open PR.
- Commits: Conventional Commits, subject ≤ 50 chars, imperative, lowercase, no trailing period, body wrapped at 72. Types: `feat fix refactor docs chore ops`.
- **No `Co-Authored-By` trailer and no "generated with" line** in commits or PR bodies. CLAUDE.md overrides any default attribution.
- vmid **104**, hostname `vault`, IP `10.0.0.132/24`, pool `LXC`, unprivileged, 1 core, 1024 MB, swap 0, 8G rootfs on `local-lvm`, `startup = "order=5,up=20"`, `features_enabled = false`.
- Dev's auth mount stays `kubernetes`, its policy stays `argocd-read`, its role stays `argocd`. The AVP config and its Secret are never touched.
- Namespaced KV paths: `secret/dev/cert-manager/cloudflare`, `secret/dev/jobboard/db`, `secret/dev/jobboard/ghcr`. Placeholder form: `<path:secret/data/dev/...#FIELD>`.
- **The narrowed policy must not be applied before the manifests point at the new paths.** `vault_seed` and `vault_configure_k8s_auth` are separate flags; seeding runs must not carry the auth flag.
- Auth runs need two inventories: `-i inventories/shared -i inventories/dev`. Install/seed runs need only the shared one.
- `ansible/secret.yaml` is ciphertext: never decrypt it, never pass it in an agent-run command, never edit it. Its `vault_kv` keys stay as they are.
- `proxmox/environments/prod` is never-applied scaffolding; the only change to it is deleting the duplicate Vault.
- Never run `terraform plan`/`apply` against Proxmox, never run a playbook against a real host, never `vault` commands against `vault-01`. Those are operator steps (Tasks 8 and 12).
- Tools: `terraform`, `tflint`, `kubectl`, `ansible-lint` on PATH; `ansible*` binaries at `/home/ubuntu/.local/share/uv/tools/ansible-lint/bin` (pipe their output through `| cat`, they fail on non-blocking IO).
- Read narrowly: `grep -n`, `sed -n`, `head`/`tail`. Do not `cat` a whole file to inspect part of it.

## File Map

| File | Change | Responsibility |
| --- | --- | --- |
| `proxmox/environments/shared/{main,variables}.tf`, `shared.tfvars.example` | modify | Owns vmid 104 |
| `proxmox/environments/dev/{main,variables}.tf`, `dev.tfvars.example` | modify | Releases vmid 104 |
| `proxmox/environments/prod/{main,variables}.tf`, `prod.tfvars.example` | modify | Drops the duplicate Vault (333) |
| `ansible/inventories/{shared,dev,prod}/hosts.yaml` | modify | `vault` group lives in shared only |
| `ansible/roles/vault/defaults/main.yaml` | modify | `vault_k8s_clusters`, `vault_kv_prefix` |
| `ansible/roles/vault/tasks/validate_clusters.yaml` | create | Rejects a malformed cluster entry |
| `ansible/roles/vault/tasks/{main,k8s_auth,seed}.yaml` | modify | Per-cluster include; prefixed seeding |
| `docs/rebuild.md`, `CLAUDE.md`, `ansible/README.md`, `proxmox/README.md` | modify | Where Vault lives, how it is reached |
| `argocd/apps/jobboard/{base,dev}/*` | move+modify | Secrets leave the env-agnostic base |
| `argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml` | modify | Prefixed placeholder |

**PR boundary:** Tasks 1-7 are PR 1 (the move; no behaviour change). Task 8 is PR 1's operator run, Task 9 its cleanup commit. Tasks 10-11 are PR 2 (the cutover), Task 12 its operator run.

---

### Task 1: Move vmid 104 in Terraform

**Files:**
- Modify: `proxmox/environments/shared/main.tf` (append), `proxmox/environments/shared/variables.tf` (append), `proxmox/environments/shared/shared.tfvars.example` (append)
- Modify: `proxmox/environments/dev/main.tf` (the `module "vault"` block), `proxmox/environments/dev/variables.tf`, `proxmox/environments/dev/dev.tfvars.example`

**Interfaces:**
- Consumes: `proxmox/modules/lxc` as-is — do not modify that module.
- Produces: `module.vault.proxmox_lxc.lxc_container` in the shared root; shared variables `debian_os_template`, `lxc_pass`, `vault_lxc_ip`.

- [ ] **Step 1: Copy the module block into the shared root**

Read `proxmox/environments/dev/main.tf`'s `module "vault"` block (from the `# HashiCorp Vault` banner to its closing `}`) and append it verbatim to `proxmox/environments/shared/main.tf`, with three edits:

- the tag becomes `tags = "lxc,vault,shared"`
- the startup comment's "ahead of nfs-01 at order=10" stays true — `nfs` in this same root is order 10
- add, after the block:

```hcl
# Adopts the existing vault-01 instead of creating a new one. Remove this
# block once the first apply has imported it: on a rebuilt host vmid 104 does
# not exist yet, and an import of a missing container fails the plan.
import {
  to = module.vault.proxmox_lxc.lxc_container
  id = "${var.pm_target_node}/lxc/104"
}
```

Everything else — the pool ACL comment, the resource sizes, `features_enabled = false` and its reasoning, `ssh_public_keys`, `start`, `start_at_node_boot`, `startup` — is copied unchanged. Those comments record incidents; do not reword them.

- [ ] **Step 2: Add the three variables to the shared root**

Append to `proxmox/environments/shared/variables.tf`:

```hcl
# Vault LXC Container Variables
variable "debian_os_template" {
  description = "Debian LXC template, e.g. 'local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst'"
  type        = string
}

variable "lxc_pass" {
  description = "Root password for LXC containers"
  type        = string
  sensitive   = true
}

variable "vault_lxc_ip" {
  description = "Vault container IP with CIDR (e.g. '10.0.0.132/24')"
  type        = string
}
```

Append to `shared.tfvars.example`:

```hcl
# Debian LXC template that must already exist on the host. It has to match a
# file actually downloaded by `pveam download local <name>` -- check
# `pveam available | grep debian-13`. docs/rebuild.md has the command.
debian_os_template = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"

# Root password for the vault container.
lxc_pass = "<PASSWORD>"

# Vault container. Must include CIDR.
vault_lxc_ip = "10.0.0.132/24"
```

- [ ] **Step 3: Release it from the dev root**

In `proxmox/environments/dev/main.tf`, replace the whole `# HashiCorp Vault` banner and `module "vault"` block with:

```hcl
################################################################################
# HashiCorp Vault -- moved to environments/shared
################################################################################
# vault-01 is the root of trust for both clusters, so it is owned by
# proxmox/environments/shared. destroy = false drops it from this state
# without touching the container. Delete this block once `terraform apply`
# here has run with it once.
removed {
  from = module.vault

  lifecycle {
    destroy = false
  }
}
```

Delete `variable "vault_lxc_ip"` (with its `# Vault LXC Container Variables` comment) from `variables.tf`, and the `# Vault container. Must include CIDR.` / `vault_lxc_ip = ...` pair from `dev.tfvars.example`.

Leave `debian_os_template` and `lxc_pass` in the dev root **only if** something else there still uses them — check with `grep -n "debian_os_template\|lxc_pass" proxmox/environments/dev/*.tf` and delete any that are now unused, along with their `dev.tfvars.example` lines.

- [ ] **Step 4: Validate both roots from a clean copy**

The workstation's `proxmox/environments/dev/.terraform` cache fails a checksum check against the committed lock file, so validate from a `git archive` copy with your edits laid over it:

```bash
cd /home/ubuntu/homelab
S=$(mktemp -d); git archive HEAD proxmox | tar -x -C $S
cp proxmox/environments/dev/main.tf proxmox/environments/dev/variables.tf $S/proxmox/environments/dev/
cp proxmox/environments/shared/main.tf proxmox/environments/shared/variables.tf $S/proxmox/environments/shared/
for e in dev shared; do (cd $S/proxmox/environments/$e && terraform init -backend=false -input=false >/dev/null && terraform validate && tflint --config=/home/ubuntu/homelab/.tflint.hcl && echo "OK $e"); done
terraform fmt -recursive -check proxmox && echo "fmt ok"
rm -rf $S
```

Expected: two `Success! The configuration is valid.` and two `OK`, no tflint output, `fmt ok`.

- [ ] **Step 5: Commit**

```bash
git add proxmox/environments/dev proxmox/environments/shared
git commit -m "refactor: move vault-01 to the shared root" -m "One Vault serves both clusters, so neither environment's apply owns it.
An import block adopts the running container; dev releases it with
destroy = false."
```

---

### Task 2: Delete the duplicate Vault from prod

**Files:**
- Modify: `proxmox/environments/prod/main.tf` (`module "vault_lxc"`, vmid 333)
- Modify: `proxmox/environments/prod/variables.tf` (`variable "vault_ip"`)
- Modify: `proxmox/environments/prod/prod.tfvars.example` (its `vault_ip` line)
- Modify: `ansible/inventories/prod/hosts.yaml` (the `vault` group and `vault-lxc` host)

**Interfaces:**
- Consumes: nothing from Task 1. Must not touch `environments/shared` or `environments/dev`.
- Produces: a prod scaffold with no Vault of its own.

- [ ] **Step 1: Check what else references them**

Run: `grep -rn "vault_ip\|vault_lxc\|vault-lxc" proxmox/environments/prod ansible/inventories/prod`

Expected: hits only in the four files above. Anything else — stop and report.

- [ ] **Step 2: Delete the module, variable and example line**

Remove the whole `module "vault_lxc" { ... }` block from `prod/main.tf` (vmid 333) and the banner comment directly above it if it names Vault. Remove `variable "vault_ip"` from `prod/variables.tf` and the `vault_ip` line from `prod.tfvars.example`.

In place of the module, leave one line so the next reader knows where it went:

```hcl
# Vault is shared: proxmox/environments/shared owns vault-01 (vmid 104), and
# both clusters authenticate against it. Do not add a second one here.
```

- [ ] **Step 3: Remove the prod inventory's vault group**

In `ansible/inventories/prod/hosts.yaml`, delete the `vault:` group with its `vault-lxc` host and `ansible_host`/`ansible_user` lines. If that leaves `children:` with no entries, leave the file valid YAML — `all:` with a comment saying the prod hosts arrive with the prod cluster, and no empty `children:` key.

- [ ] **Step 4: Verify the prod inventory still parses**

```bash
cd ansible && /home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-inventory -i inventories/prod --graph 2>&1 | cat
ansible-lint . 2>&1 | tail -3
```

Expected: the graph prints without error (an inventory with no hosts is fine), and ansible-lint reports `Passed`.

CI does not validate the prod Terraform root, so `terraform validate` there is optional; if you run it, do it from a `git archive` copy as in Task 1.

- [ ] **Step 5: Commit**

```bash
git add proxmox/environments/prod ansible/inventories/prod
git commit -m "chore: drop the duplicate vault from prod" -m "Prod authenticates against the shared vault-01; a second one would be a
second unseal ritual and a second silent failure after a power loss."
```

---

### Task 3: Move the `vault` group to the shared inventory

**Files:**
- Modify: `ansible/inventories/shared/hosts.yaml` (add the `vault` group)
- Modify: `ansible/inventories/dev/hosts.yaml` (remove it)

**Interfaces:**
- Consumes: `host_ips['vault-01']`, `proxmox_vm_ids['vault-01']` from `secret.yaml` (supplied by the operator at run time).
- Produces: `inventories/shared` resolving group `vault` → host `vault-01`. `playbooks/vault.yaml` (`hosts: vault`) is unchanged.

- [ ] **Step 1: Read dev's vault group and move it verbatim**

Run: `grep -n -A12 "^    vault:" ansible/inventories/dev/hosts.yaml`

Append that group — including its `vars: ansible_user: root` override and the whole comment above it explaining why (the Debian LXC template has only root; without the override the play fails at the connection) — under `children:` in `ansible/inventories/shared/hosts.yaml`, after the `nfs` group. Then delete it from `inventories/dev/hosts.yaml`.

Update the shared inventory's header comment so it covers both hosts, e.g. "nfs-01 serves both clusters' shares and vault-01 is the root of trust for both, so neither belongs to one environment's inventory."

- [ ] **Step 2: Verify both inventories**

```bash
cd ansible
B=/home/ubuntu/.local/share/uv/tools/ansible-lint/bin
$B/ansible-inventory -i inventories/shared --graph 2>&1 | cat
$B/ansible-inventory -i inventories/dev --graph 2>&1 | cat
$B/ansible-inventory -i inventories/shared -i inventories/dev --graph 2>&1 | cat
```

Expected: shared shows `@nfs` and `@vault` (with `vault-01`); dev shows `k8s_cluster`, `claude_code` and **no** `vault`; the combined run shows all of them — that combination is what a Kubernetes-auth run uses.

- [ ] **Step 3: Syntax-check the playbook against the shared inventory**

```bash
cd ansible && /home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/shared playbooks/vault.yaml --syntax-check 2>&1 | cat
```

Expected: `playbook: playbooks/vault.yaml`.

- [ ] **Step 4: Commit**

```bash
git add ansible/inventories
git commit -m "refactor: move vault-01 to the shared inventory"
```

---

### Task 4: Teach the role about many clusters

**Files:**
- Modify: `ansible/roles/vault/defaults/main.yaml` (append)
- Create: `ansible/roles/vault/tasks/validate_clusters.yaml`
- Modify: `ansible/roles/vault/tasks/main.yaml`
- Modify: `ansible/roles/vault/tasks/k8s_auth.yaml` (literals → `cluster.*`)
- Test (scratch, not committed): `$SCRATCH/vault-clusters-test.yaml` where `SCRATCH` is the session scratchpad directory

**Interfaces:**
- Consumes: the inventory from Task 3; `host_ips` from `secret.yaml`.
- Produces: `vault_k8s_clusters` (list of dicts with keys `name, auth_path, api_host, control_plane_host, policy_name, role_name, service_account_names, service_account_namespaces`), loop variable named `cluster`, and `tasks/validate_clusters.yaml` which fails on a malformed entry.

- [ ] **Step 1: Write the failing test**

Create `$SCRATCH/vault-clusters-test.yaml`:

```yaml
- name: A complete cluster entry passes validation
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    vault_k8s_clusters:
      - name: dev
        auth_path: kubernetes
        api_host: 10.0.0.101
        control_plane_host: master-01
        policy_name: argocd-read
        role_name: argocd
        service_account_names: ["argocd-repo-server"]
        service_account_namespaces: ["argocd"]
  tasks:
    - name: Validate
      ansible.builtin.include_tasks: /home/ubuntu/homelab/ansible/roles/vault/tasks/validate_clusters.yaml

- name: An entry missing a key is rejected, naming the entry and the key
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    vault_k8s_clusters:
      - name: prod
        auth_path: kubernetes-prod
        api_host: 10.0.0.150
  tasks:
    - name: Validate, expecting failure
      block:
        - ansible.builtin.include_tasks: /home/ubuntu/homelab/ansible/roles/vault/tasks/validate_clusters.yaml
        - ansible.builtin.fail:
            msg: "validate_clusters.yaml accepted an entry with no policy_name"
      rescue:
        - name: The failure message names the cluster and a missing key
          ansible.builtin.assert:
            that:
              - "'prod' in ansible_failed_result.msg"
              - "'policy_name' in ansible_failed_result.msg"
            fail_msg: "unhelpful failure: {{ ansible_failed_result.msg }}"

- name: Duplicate auth paths are rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    vault_k8s_clusters:
      - name: dev
        auth_path: kubernetes
        api_host: 10.0.0.101
        control_plane_host: master-01
        policy_name: argocd-read
        role_name: argocd
        service_account_names: ["argocd-repo-server"]
        service_account_namespaces: ["argocd"]
      - name: prod
        auth_path: kubernetes
        api_host: 10.0.0.150
        control_plane_host: prod-master-01
        policy_name: argocd-read-prod
        role_name: argocd
        service_account_names: ["argocd-repo-server"]
        service_account_namespaces: ["argocd"]
  tasks:
    - name: Validate, expecting failure
      block:
        - ansible.builtin.include_tasks: /home/ubuntu/homelab/ansible/roles/vault/tasks/validate_clusters.yaml
        - ansible.builtin.fail:
            msg: "validate_clusters.yaml accepted two clusters on one auth path"
      rescue:
        - name: The failure message names the shared auth path
          ansible.builtin.assert:
            that: "'kubernetes' in ansible_failed_result.msg"
```

Two clusters sharing an `auth_path` would have the second silently overwrite the first's `kubernetes_host` — one cluster's ArgoCD would then authenticate against the other's API server. That is the mistake worth failing on.

- [ ] **Step 2: Run it to verify it fails**

```bash
SCRATCH=/tmp/claude-1000/-home-ubuntu-homelab/051a728c-13d3-4268-a0a0-35f7b455d4b8/scratchpad
/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i localhost, $SCRATCH/vault-clusters-test.yaml 2>&1 | cat
```

Expected: FAIL on the first play — `validate_clusters.yaml` does not exist yet.

- [ ] **Step 3: Write `tasks/validate_clusters.yaml`**

```yaml
---
# A malformed entry here misconfigures Vault in ways that surface much later
# and look like something else: a missing key renders an empty URL segment,
# and two clusters on one auth_path make the second overwrite the first's
# kubernetes_host, so one cluster's ArgoCD silently authenticates against the
# other cluster's API server.
- name: Require every cluster entry to be complete
  ansible.builtin.assert:
    that:
      - item.name is defined and item.name | length > 0
      - item.auth_path is defined and item.auth_path | length > 0
      - item.api_host is defined and item.api_host | length > 0
      - item.control_plane_host is defined and item.control_plane_host | length > 0
      - item.policy_name is defined and item.policy_name | length > 0
      - item.role_name is defined and item.role_name | length > 0
      - item.service_account_names is defined and item.service_account_names | length > 0
      - item.service_account_namespaces is defined and item.service_account_namespaces | length > 0
    fail_msg: >-
      vault_k8s_clusters entry {{ item.name | default('(unnamed)') }} is
      incomplete. Every entry needs name, auth_path, api_host,
      control_plane_host, policy_name, role_name, service_account_names and
      service_account_namespaces. Got: {{ item.keys() | list | sort | join(', ') }}
    quiet: true
  loop: "{{ vault_k8s_clusters }}"
  loop_control:
    label: "{{ item.name | default('(unnamed)') }}"

- name: Require each cluster to have its own auth path
  ansible.builtin.assert:
    that:
      - (vault_k8s_clusters | map(attribute='auth_path') | list | unique | length)
        == (vault_k8s_clusters | length)
    fail_msg: >-
      Two vault_k8s_clusters entries share an auth_path
      ({{ vault_k8s_clusters | map(attribute='auth_path') | list | join(', ') }}).
      The second would overwrite the first's kubernetes_host.
    quiet: true
```

- [ ] **Step 4: Run the test again**

Same command as Step 2. Expected: all three plays pass, `failed=0`. The second and third plays pass by way of their `rescue` assertions.

- [ ] **Step 5: Add the defaults**

Append to `ansible/roles/vault/defaults/main.yaml`:

```yaml
# One entry per cluster that authenticates against this Vault. Only dev
# exists; the prod entry (auth_path: kubernetes-prod, its own api_host and
# control_plane_host, policy_name: argocd-read-prod) arrives with the prod
# cluster, against an API server that exists to be configured.
#
# dev's auth_path, policy_name and role_name are the values Vault already
# holds and argocd-vault-plugin already uses. Changing them means
# reconfiguring AVP's Secret, which this role does not do.
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

- [ ] **Step 6: Rewrite `tasks/k8s_auth.yaml` in terms of `cluster`**

This file now configures **one** cluster and is included once per entry. Keep every existing comment — they record real incidents (the no_log reviewer JWT, the 200-vs-204 warning body, the empty-stdout case). Replace the literals:

| Was | Becomes |
| --- | --- |
| `delegate_to: "{{ groups['k8s_control_plane'][0] }}"` (both reads) | `delegate_to: "{{ cluster.control_plane_host }}"` |
| `/v1/sys/auth/kubernetes` | `/v1/sys/auth/{{ cluster.auth_path }}` |
| `/v1/auth/kubernetes/config` | `/v1/auth/{{ cluster.auth_path }}/config` |
| `kubernetes_host: "https://{{ host_ips['master-01'] }}:6443"` | `kubernetes_host: "https://{{ cluster.api_host }}:6443"` |
| `/v1/sys/policies/acl/argocd-read` | `/v1/sys/policies/acl/{{ cluster.policy_name }}` |
| `/v1/auth/kubernetes/role/argocd` | `/v1/auth/{{ cluster.auth_path }}/role/{{ cluster.role_name }}` |
| `bound_service_account_names: ["argocd-repo-server"]` | `bound_service_account_names: "{{ cluster.service_account_names }}"` |
| `bound_service_account_namespaces: ["argocd"]` | `bound_service_account_namespaces: "{{ cluster.service_account_namespaces }}"` |
| `policies: ["argocd-read"]` | `policies: ["{{ cluster.policy_name }}"]` |

The registered variables (`vault_k8s_ca`, `vault_k8s_jwt`, `vault_k8s_auth`) keep their names — each include runs to completion before the next begins.

The policy body becomes prefixed (this is what narrows dev's access; per the Global Constraints it takes effect only when an operator runs with `vault_configure_k8s_auth: true`, which Task 12 sequences after the manifests):

```yaml
      policy: |
        path "secret/data/{{ cluster.name }}/*" {
          capabilities = ["read"]
        }
        path "secret/metadata/{{ cluster.name }}/*" {
          capabilities = ["list", "read"]
        }
```

Add a comment above it recording why it is prefixed: one Vault serves both clusters, and an unprefixed `secret/data/*` would let either read the other's secrets.

- [ ] **Step 7: Include it per cluster from `main.yaml`**

Replace the `Configure Kubernetes authentication` task in `ansible/roles/vault/tasks/main.yaml` with:

```yaml
- name: Check the cluster list
  ansible.builtin.import_tasks: validate_clusters.yaml
  when: vault_configure_k8s_auth | default(false) | bool

- name: Configure Kubernetes authentication for each cluster
  ansible.builtin.include_tasks: k8s_auth.yaml
  loop: "{{ vault_k8s_clusters }}"
  loop_control:
    loop_var: cluster
    label: "{{ cluster.name }}"
  when: vault_configure_k8s_auth | default(false) | bool
```

- [ ] **Step 8: Lint and syntax-check**

```bash
cd ansible && ansible-lint . && /home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i inventories/shared playbooks/vault.yaml --syntax-check 2>&1 | cat
```

Expected: `Passed: 0 failure(s), 0 warning(s)` and `playbook: playbooks/vault.yaml`. Then re-run the Step 2 test command once more — all three plays still pass against the committed role.

- [ ] **Step 9: Commit**

```bash
git add ansible/roles/vault
git commit -m "feat: configure vault k8s auth per cluster" -m "One Vault serves both clusters, so the auth mount, policy and role come
from a list rather than literals, and each policy is scoped to its own
secret/data/<env>/ prefix. Validation refuses an incomplete entry or two
clusters sharing an auth path."
```

---

### Task 5: Seed under an environment prefix

**Files:**
- Modify: `ansible/roles/vault/defaults/main.yaml` (add `vault_kv_prefix`)
- Modify: `ansible/roles/vault/tasks/seed.yaml` (the `Seed the KV paths` task's URL)
- Test (scratch): `$SCRATCH/vault-seed-test.yaml`

**Interfaces:**
- Consumes: `vault_kv` from `secret.yaml` — its keys are unchanged and the file is never edited.
- Produces: seeded paths at `secret/data/{{ vault_kv_prefix }}/<key>`; `vault_kv_prefix` defaults to `dev`.

- [ ] **Step 1: Write the failing test**

Create `$SCRATCH/vault-seed-test.yaml`. It asserts the URL the seed task builds, without talking to Vault, by rendering the same expression the task uses from the role's own defaults:

```yaml
- name: The seed URL carries the environment prefix
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - /home/ubuntu/homelab/ansible/roles/vault/defaults/main.yaml
  vars:
    vault_kv:
      jobboard/db: {POSTGRES_PASSWORD: x}
      cert-manager/cloudflare: {API_TOKEN: y}
  tasks:
    - name: Build one URL per key the way seed.yaml does
      ansible.builtin.set_fact:
        urls: >-
          {{ vault_kv | dict2items
             | map(attribute='key')
             | map('regex_replace', '^', 'http://10.0.0.132:' ~ vault_api_port ~ '/v1/secret/data/' ~ vault_kv_prefix ~ '/')
             | list }}

    - name: Every path is under the prefix, and the prefix defaults to dev
      ansible.builtin.assert:
        that:
          - vault_kv_prefix == 'dev'
          - "'http://10.0.0.132:8200/v1/secret/data/dev/jobboard/db' in urls"
          - "'http://10.0.0.132:8200/v1/secret/data/dev/cert-manager/cloudflare' in urls"
        fail_msg: "{{ urls }}"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
/home/ubuntu/.local/share/uv/tools/ansible-lint/bin/ansible-playbook -i localhost, $SCRATCH/vault-seed-test.yaml 2>&1 | cat
```

Expected: FAIL — `vault_kv_prefix` is undefined in the role's defaults.

- [ ] **Step 3: Add the default**

Append to `ansible/roles/vault/defaults/main.yaml`:

```yaml
# Secrets are namespaced per environment so one Vault can serve both
# clusters: dev's live under secret/dev/, prod's under secret/prod/, and each
# cluster's policy grants only its own prefix. The keys in secret.yaml's
# vault_kv block stay unprefixed -- that file is ansible-vault ciphertext and
# does not need editing to add an environment.
vault_kv_prefix: dev
```

- [ ] **Step 4: Prefix the seed URL**

In `ansible/roles/vault/tasks/seed.yaml`, change the `Seed the KV paths` task's URL from `/v1/secret/data/{{ item.key }}` to:

```yaml
    url: >-
      http://{{ ansible_facts['default_ipv4']['address'] }}:{{ vault_api_port }}/v1/secret/data/{{ vault_kv_prefix }}/{{ item.key }}
```

Nothing else in the task changes — it keeps `no_log: true`, the `status_code: 200`, and the loop over `vault_kv | dict2items`.

- [ ] **Step 5: Run the test again**

Same command as Step 2. Expected: PASS, `failed=0`.

- [ ] **Step 6: Lint**

```bash
cd ansible && ansible-lint . 2>&1 | tail -3
```

Expected: `Passed: 0 failure(s), 0 warning(s)`.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/vault
git commit -m "feat: seed vault kv under an env prefix" -m "secret.yaml's vault_kv keys stay as they are; the prefix decides which
environment's tree they land in."
```

---

### Task 6: Documentation for the move

**Files:**
- Modify: `CLAUDE.md` (Layout block, the LXC-template bullet, the sealed-Vault bullet, the Secrets section)
- Modify: `docs/rebuild.md` (rebuild order steps 4 and 8, the vault playbook invocations, the LXC-template blocker)
- Modify: `ansible/README.md` (the vault playbook section, around lines 195-225)
- Modify: `proxmox/README.md` (the shared tree)

**Interfaces:**
- Consumes: names from Tasks 1-5: `proxmox/environments/shared`, `inventories/shared`, `vault_k8s_clusters`, `vault_kv_prefix`, the `secret/dev/*` paths.

Locate every anchor with `grep -n` by content; line numbers drift.

- [ ] **Step 1: `CLAUDE.md` — Layout**

Change the `environments/shared/` line to name both hosts:

```txt
                  environments/shared/  nfs-01 and vault-01, serving both
```

- [ ] **Step 2: `CLAUDE.md` — the LXC template bullet**

It currently says the Debian LXC template must exist before any *dev* apply, and that `module "vault"` clones it for `vault-01`, failing "on vmid 104". Update it: the template is needed before the **shared** apply, and a missing template fails there, not in dev.

- [ ] **Step 3: `CLAUDE.md` — the sealed-Vault bullet**

Add, at the end of that bullet: one Vault now serves both clusters from `proxmox/environments/shared`, so a seal stops both — and `vault status` on `vault-01` remains the first check when an app that was fine yesterday will not sync.

- [ ] **Step 4: `CLAUDE.md` — the Secrets section**

The three-places paragraph stays true; add that Vault's KV is namespaced per environment (`secret/dev/...`, later `secret/prod/...`), each cluster's policy grants only its own prefix, and the committed placeholder form is therefore `<path:secret/data/dev/...#FIELD>`. Update the existing `<path:secret/data/...>` bullet's example accordingly.

- [ ] **Step 5: `docs/rebuild.md`**

- The rebuild-order step that applies `shared`: it now creates `vault-01` (vmid 104, order 5) as well as `nfs-01` (order 10), and needs the Debian LXC template.
- The Vault step ("Install and unseal Vault"): the playbook runs with `-i inventories/shared`; the seeding run stays `-e vault_seed=true -e vault_token=...`; the Kubernetes-auth run needs **both** inventories: `-i inventories/shared -i inventories/dev`, because the role delegates the CA and token-reviewer reads to a control-plane host that lives in the dev inventory.
- Wherever the KV paths are named, they are now `secret/dev/...`.
- The LXC-template blocker moves from the dev apply to the shared apply.

- [ ] **Step 6: `ansible/README.md`**

In the Vault section (around lines 195-225), add `-i inventories/shared` to the install and seed commands and `-i inventories/shared -i inventories/dev` to the k8s-auth command, and note that seeding writes under `vault_kv_prefix` (default `dev`) while `secret.yaml`'s keys stay unprefixed. Update the tree at the top of the file if it lists inventories.

- [ ] **Step 7: `proxmox/README.md`**

Add `vault-01` to the `environments/shared/` description, and mention `modules/lxc` backs it — the existing `modules/lxc` bullet says it backs `vault-01` in `environments/dev`; correct that to `environments/shared`.

- [ ] **Step 8: Check nothing still says Vault lives in dev**

```bash
grep -rn -E "environments/dev.*vault|vault.*environments/dev|inventories/dev.*vault|vault_lxc_ip" --include=*.md . | grep -v docs/superpowers/
```

Expected: no hits, or only ones still true. Fix any that are not.

- [ ] **Step 9: pre-commit and commit**

```bash
pre-commit run --all-files
git add CLAUDE.md docs/rebuild.md ansible/README.md proxmox/README.md
git commit -m "docs: vault is shared by both clusters"
```

Expected: all hooks Passed.

---

### Task 7: Review and open PR 1

**Files:** none changed; writes the PR body to the scratchpad.

- [ ] **Step 1: Full verification**

```bash
cd /home/ubuntu/homelab
S=$(mktemp -d); git archive HEAD proxmox | tar -x -C $S
for e in dev shared; do (cd $S/proxmox/environments/$e && terraform init -backend=false -input=false >/dev/null && terraform validate && tflint --config=/home/ubuntu/homelab/.tflint.hcl && echo "OK $e"); done; rm -rf $S
terraform fmt -recursive -check proxmox && echo "fmt ok"
cd ansible && ansible-lint . 2>&1 | tail -2 && cd ..
pre-commit run --all-files
scripts/check-manifests.sh >/dev/null && echo "manifests ok"
git status --short
```

Expected: two `Success!`/`OK`, `fmt ok`, ansible-lint `Passed`, all hooks Passed, `manifests ok`, clean tree.

- [ ] **Step 2: Code review** — invoke `superpowers:requesting-code-review` on the branch diff from `main`. Fix findings on the branch.

- [ ] **Step 3: Pre-merge checks** — invoke `superpowers:finishing-a-development-branch`; choose "push and open a PR". Never merge.

- [ ] **Step 4: Write the PR body** to `$SCRATCH/pr-vault-1.md`:

```markdown
Moves `vault-01` (vmid 104) out of the dev environment into
`proxmox/environments/shared` and `ansible/inventories/shared`, deletes the
duplicate Vault (vmid 333) from the prod scaffolding, and makes the `vault`
role able to configure any number of clusters.

**Dev's behaviour does not change in this PR.** The old KV paths still exist
and dev's policy still grants them; the narrowed policy and the prefixed
paths take effect in the follow-up cutover PR.

Spec: `docs/superpowers/specs/2026-09-23-vault-shared-design.md`
Plan: `docs/superpowers/plans/2026-09-23-vault-shared.md`

## Do not merge until the operator steps are done

`proxmox/environments/shared/main.tf` carries a one-shot `import` block and
`dev/main.tf` a `removed` block. Both are dropped in a follow-up commit on
this branch once both applies have run — on a rebuilt host vmid 104 does not
exist and the import would fail the plan.

## Operator steps — in order (plan Task 8)

1. dev: `terraform plan -var-file=dev.tfvars` shows one resource *no longer
   managed*, nothing else from this diff. Apply.
2. shared: add the three new values to `shared.tfvars`, then
   `terraform plan -var-file=shared.tfvars` shows 1 import, in-place only,
   **0 to destroy, no replacement**. Apply.
   **If it demands a restart of the container, stop** — Vault is the root of
   trust for every app with a `<path:...>` placeholder.
3. `pct status 104` still running; `vault status` still unsealed; the dev
   apps still `Synced`.
4. Follow-up commit dropping the `import` and `removed` blocks; both plans
   then show `No changes.`

## Checks

- `terraform validate` / `fmt` / `tflint` on dev and shared
- `ansible-lint` (production), `vault.yaml --syntax-check -i inventories/shared`
- role validation and seed-prefix tests via a scratch playbook
- `pre-commit run --all-files`, `scripts/check-manifests.sh`
```

- [ ] **Step 5: Push and open**

```bash
git push -u origin vault-shared
gh pr create --base main --head vault-shared --title "refactor: move vault-01 to the shared environment" --body-file $SCRATCH/pr-vault-1.md
```

Report the URL. Do not merge.

---

### Task 8: Operator steps for PR 1 (repository owner runs these)

Not for agents. Run from the branch checkout, in order. Any unexpected output: stop and report.

- [ ] **Step 1: dev plan and apply**

Delete the `vault_lxc_ip` line from your real `dev.tfvars`, then:

```bash
cd proxmox/environments/dev
terraform plan -var-file=dev.tfvars
```

Expected: `module.vault.proxmox_lxc.lxc_container will no longer be managed by Terraform` and nothing else from this change. (Pre-existing drift on other VMs may appear; it is unrelated.) Then `terraform apply -var-file=dev.tfvars`.

- [ ] **Step 2: shared plan and apply**

Add `debian_os_template`, `lxc_pass` and `vault_lxc_ip` to `shared.tfvars`, copying the values from `dev.tfvars`. Then:

```bash
cd ../shared
terraform plan -var-file=shared.tfvars
```

Expected: `module.vault.proxmox_lxc.lxc_container will be imported`, in-place updates only (tags, bookkeeping), **`0 to destroy`, no `must be replaced`**.

**If the provider refuses with a restart requirement**, stop and report the exact error. Vault is the root of trust; the equivalent situation on `nfs-01` was resolved by making the change on the host and letting Terraform reconcile, and the same approach applies here — but it is a decision, not a default.

Then `terraform apply -var-file=shared.tfvars`.

- [ ] **Step 3: Verify nothing moved underneath Vault**

```bash
pct status 104                      # on the host: running
pct config 104 | grep -E '^(hostname|memory|rootfs|onboot|startup)'
ssh root@10.0.0.132 'systemctl is-active vault; VAULT_ADDR=http://127.0.0.1:8200 vault status | head -5'
kubectl -n argocd get applications   # dev apps still Synced
```

Expected: running, config unchanged, `vault` active and **unsealed**, apps `Synced`. A sealed Vault here means the container restarted — say so before going further.

- [ ] **Step 4: Report back** so the plan's Task 9 cleanup commit can be made.

---

### Task 9: Drop the one-shot blocks (PR 1 follow-up)

Run only after Task 8 Steps 1 and 2 are reported applied.

**Files:**
- Modify: `proxmox/environments/shared/main.tf` (the `import` block and its comment)
- Modify: `proxmox/environments/dev/main.tf` (the `removed` block, replaced by a one-line pointer)

- [ ] **Step 1: Delete both blocks**

In `shared/main.tf` remove the `# Adopts the existing vault-01 ...` comment and the `import { ... }` block. In `dev/main.tf` replace the banner, comment and `removed { ... }` block with:

```hcl
# vault-01 (vmid 104) lives in proxmox/environments/shared.
```

- [ ] **Step 2: Validate**

```bash
S=$(mktemp -d); git archive HEAD proxmox | tar -x -C $S
cp proxmox/environments/dev/main.tf $S/proxmox/environments/dev/; cp proxmox/environments/shared/main.tf $S/proxmox/environments/shared/
for e in dev shared; do (cd $S/proxmox/environments/$e && terraform init -backend=false -input=false >/dev/null && terraform validate && echo "OK $e"); done; rm -rf $S
terraform fmt -recursive -check proxmox && echo "fmt ok"
```

Expected: two `Success!`/`OK`, `fmt ok`.

- [ ] **Step 3: Ask the owner to confirm both plans are empty** — `terraform plan` in `dev` and `shared` both report `No changes.` for Vault.

- [ ] **Step 4: Commit and push**

```bash
git add proxmox/environments/dev/main.tf proxmox/environments/shared/main.tf
git commit -m "chore: drop one-shot vault import and removed blocks" -m "Both applies have run. On a rebuilt host vmid 104 does not exist, and an
import block for it would fail the shared plan."
git push
```

PR 1 can then be merged by the owner.

---

### Task 10: Namespace the manifests (PR 2)

Start this only after PR 1 is merged. Branch from the updated `main`:
`git checkout main && git pull && git checkout -b vault-paths`.

**Files:**
- Move: `argocd/apps/jobboard/base/secret.yaml` → `argocd/apps/jobboard/dev/secret.yaml`
- Move: `argocd/apps/jobboard/base/ghcr-secret.yaml` → `argocd/apps/jobboard/dev/ghcr-secret.yaml`
- Modify: `argocd/apps/jobboard/base/kustomization.yaml` (drop both resources)
- Modify: `argocd/apps/jobboard/dev/kustomization.yaml` (add both resources)
- Modify: `argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml` (the placeholder)

**Interfaces:**
- Consumes: the prefixed paths Task 5 seeds — `secret/dev/jobboard/db`, `secret/dev/jobboard/ghcr`, `secret/dev/cert-manager/cloudflare`.
- Produces: an env-agnostic `jobboard/base` that a future prod overlay can consume.

- [ ] **Step 1: Move the two jobboard secret manifests**

```bash
git mv argocd/apps/jobboard/base/secret.yaml argocd/apps/jobboard/dev/secret.yaml
git mv argocd/apps/jobboard/base/ghcr-secret.yaml argocd/apps/jobboard/dev/ghcr-secret.yaml
```

Remove `- secret.yaml` and `- ghcr-secret.yaml` from `base/kustomization.yaml`'s `resources`, and add them to `dev/kustomization.yaml`'s `resources` (which already lists `../base` and `ingress.yaml`). Add a comment in the base kustomization saying secrets are per environment because their Vault paths are: `secret/dev/...` versus `secret/prod/...`.

- [ ] **Step 2: Prefix all five placeholders**

```bash
sed -i 's|<path:secret/data/jobboard/|<path:secret/data/dev/jobboard/|g' argocd/apps/jobboard/dev/secret.yaml argocd/apps/jobboard/dev/ghcr-secret.yaml
sed -i 's|<path:secret/data/cert-manager/|<path:secret/data/dev/cert-manager/|g' argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml
grep -rn "<path:secret" argocd | sed -E 's/.*(<path:[^>]*>).*/\1/' | sort
```

Expected: five placeholders, every one beginning `<path:secret/data/dev/`.

- [ ] **Step 3: Render both overlays**

```bash
kustomize build argocd/apps/jobboard/dev | grep -n -E "kind: Secret|<path:" 
kustomize build argocd/apps/jobboard/base | grep -c "kind: Secret"
kustomize build argocd/apps/cert-manager-issuers/dev | grep -n "<path:"
scripts/check-manifests.sh
```

Expected: the dev overlay still renders both Secrets, each with a `secret/data/dev/...` placeholder; the **base renders zero Secrets** (that is the point of the move); cert-manager's issuer secret carries the prefixed path; `check-manifests.sh` exits 0.

- [ ] **Step 4: Confirm the AVP placeholder form is intact**

```bash
grep -rn "path:secret" argocd | grep -v "<path:secret/data/dev/" || echo "all prefixed"
```

Expected: `all prefixed`. A placeholder that lost its `<...>` wrapper or its `#FIELD` suffix renders as a literal string into a Secret — never "fix" one by substituting a real value.

- [ ] **Step 5: pre-commit and commit**

```bash
pre-commit run --all-files
git add argocd
git commit -m "refactor: namespace dev secrets under secret/dev" -m "One Vault serves both clusters, so each environment's secrets live under
its own prefix and its policy grants only that. The jobboard secrets leave
the base overlay, which a prod overlay will also consume."
```

- [ ] **Step 6: Review and open PR 2**

Invoke `superpowers:requesting-code-review`, then `superpowers:finishing-a-development-branch` (push and open a PR, never merge). The PR body must carry the cutover order from Task 12 and this warning: **merging is a deploy, and the new paths must be seeded before the merge, or every app with a placeholder goes `ComparisonError`.**

---

### Task 11: Verify the cutover is reversible before it runs

**Files:** none changed. This is a written check the agent performs and reports; it is the last gate before Task 12.

- [ ] **Step 1: Confirm the order in the PR body matches the plan**

Read back PR 2's body and check it says, in this order: seed first → merge → verify → narrow the policy → delete the old paths. Any other order has a window where dev's manifests name paths that do not exist or that its policy forbids.

- [ ] **Step 2: Confirm the rollback**

Write into the PR body the rollback for each step, and check each is true against the repo:
- before the merge: nothing has changed; the old paths still serve dev.
- after the merge, before the policy narrows: revert the PR — the old paths still exist and still resolve.
- after the policy narrows: re-run the role with the previous (unprefixed) policy, or revert the PR and re-run; the old paths are still there because they are deleted last.
- after the old paths are deleted: only the new paths exist. Reverting the manifests now requires re-seeding the old paths from `secret.yaml` (`vault_seed=true` with `vault_kv_prefix=''`). Say so explicitly — this is the point of no easy return.

---

### Task 12: Operator steps for PR 2 (repository owner runs these)

Not for agents. In this order.

- [ ] **Step 1: Seed the prefixed paths (before merging)**

```bash
cd ansible
ansible-playbook -i inventories/shared playbooks/vault.yaml -e @secret.yaml --ask-vault-pass \
  -e vault_seed=true -e vault_token=<root token>
```

Then on `vault-01`, confirm both trees exist and match:

```bash
VAULT_ADDR=http://127.0.0.1:8200 vault kv get secret/dev/jobboard/db
VAULT_ADDR=http://127.0.0.1:8200 vault kv get secret/jobboard/db
```

Expected: the same fields and values under both. **Do not pass `vault_configure_k8s_auth` on this run** — that would narrow the policy while the manifests still name the old paths.

- [ ] **Step 2: Merge PR 2**

ArgoCD picks it up on its next poll (~3 min).

- [ ] **Step 3: Verify the apps resolved the new paths**

```bash
kubectl -n argocd get applications
kubectl -n jobboard get secret jobboard-secrets -o jsonpath='{.data.DATABASE_URL}' | base64 -d | head -c 20; echo
kubectl -n cert-manager get secret cloudflare-api-token -o jsonpath='{.data.API_TOKEN}' | base64 -d | wc -c
kubectl -n jobboard get pods
```

Expected: `jobboard` and `cert-manager-issuers` `Synced`, the Secrets holding real values (not empty, not the literal `<path:...>`), pods running. Names may differ — check the manifests for the actual Secret names.

- [ ] **Step 4: Narrow the policy**

```bash
ansible-playbook -i inventories/shared -i inventories/dev playbooks/vault.yaml -e @secret.yaml --ask-vault-pass \
  -e vault_configure_k8s_auth=true -e vault_token=<root token>
```

Both inventories are required: the role delegates the CA and token-reviewer reads to `master-01`, which lives in the dev inventory.

Then force a re-sync and re-check the Secrets from Step 3 — this proves AVP still authenticates and can still read under the narrowed policy.

- [ ] **Step 5: Delete the old paths**

```bash
# on vault-01
export VAULT_ADDR=http://127.0.0.1:8200
vault kv metadata delete secret/jobboard/db
vault kv metadata delete secret/jobboard/ghcr
vault kv metadata delete secret/cert-manager/cloudflare
vault kv list secret/          # dev/ only
vault kv list secret/dev/      # cert-manager, jobboard
```

- [ ] **Step 6: Final check**

Re-sync the two apps once more and confirm their Secrets still hold real values. Then reboot `vault-01`, unseal it by hand, and confirm the apps recover — the seal is expected; the recovery is what is being tested.

- [ ] **Step 7: Report back.** Task 10's plan checkboxes are ticked by the supervisor on this report, not before.
