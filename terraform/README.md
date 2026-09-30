# Proxmox Terraform Setup

Three Terraform roots, one per state file. `dev` holds the kubeadm
cluster and `claude-code`; `shared` holds what outlives any one cluster —
`nfs-01`, `vault-02` and the LAN LXCs; `prod` is never-applied
scaffolding for the planned Talos cluster (roadmap sub-project 2, ADR
[0012](../docs/decisions/0012-hub-and-spoke-topology.md)). The layout:

```txt
terraform/
├── README.md
├── environments/
│   ├── dev/
│   │   ├── .terraform.lock.hcl
│   │   ├── backend.tf.example   # gitignored backend.tf copies from this
│   │   ├── dev.tfvars.example   # gitignored dev.tfvars copies from this
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── shared/
│   │   ├── .terraform.lock.hcl
│   │   ├── backend.tf.example
│   │   ├── main.tf              # nfs-01, vault-02, the LAN LXCs
│   │   ├── outputs.tf
│   │   ├── shared.tfvars.example
│   │   ├── variables.tf
│   │   └── versions.tf
│   └── prod/                    # never applied; cannot init yet
│       ├── .terraform.lock.hcl
│       ├── backend.tf.example
│       ├── main.tf
│       ├── outputs.tf
│       ├── prod.tfvars.example
│       ├── variables.tf
│       └── versions.tf
├── modules/
│   ├── lxc/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── nfs-server/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── vault-vm/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── talos-k8s/
│   ├── talos-vm/
│   ├── ubuntu-k8s/
│   └── ubuntu-vm/
└── ...
```

---

## Environment Setup

### Prerequisites & Installation

You’ll need the following tools installed locally:

- `terraform`

On macOS, the easiest path is Homebrew:

```bash
brew install terraform
```

## Sensitive Terraform files

There is no SOPS here, no `.enc` file, and no `.sops.yaml` -- check
`git ls-files | grep -i 'enc\|sops'` and it comes back empty. `*.tfvars`
is gitignored instead and has no backup anywhere but the workstation it
was created on: losing it means re-issuing a Proxmox API token and
retyping the cloud-init password from scratch, not decrypting anything.

```bash
cp terraform/environments/dev/dev.tfvars.example terraform/environments/dev/dev.tfvars
# then fill in pm_api_token_id, pm_api_token_secret, the SSH key paths and
# the cloud-init password by hand

cp terraform/environments/dev/backend.tf.example terraform/environments/dev/backend.tf
# local backend, state file next to main.tf -- nothing to fill in

cp terraform/environments/shared/shared.tfvars.example terraform/environments/shared/shared.tfvars
# same fields as dev.tfvars, plus nfs-01's and vault-02's IPs

cp terraform/environments/shared/backend.tf.example terraform/environments/shared/backend.tf
```

`backend.tf` is gitignored alongside `*.tfvars`, for the same reason: it is
a per-checkout file, not a secret, but keeping it out of git means every
checkout copies it from the committed `.example` once. State itself is
local (`terraform.tfstate` next to `main.tf`), not a remote backend, so
there is no bucket or credential involved in either file.

---

## Initialising an Environment

```bash
cd terraform/environments/dev   # or shared
terraform init
```

There is no remote backend to bootstrap. `backend.tf` declares `local`
state, and `terraform init` just needs that file and the providers cached
-- nothing external to prepare first.

---

## Routine Terraform Commands

### Development (Dev)

```bash
cd terraform/environments/dev
terraform plan  -var-file="dev.tfvars"
terraform apply -var-file="dev.tfvars"
```

### Shared

```bash
cd terraform/environments/shared
terraform plan  -var-file="shared.tfvars"
terraform apply -var-file="shared.tfvars"
```

### Prod — not yet

`environments/prod` has never been applied and cannot `terraform init`:
it pins `telmate/proxmox` `3.0.2-rc04` and Terraform `~> 1.13.0`, while
`modules/talos-vm` pins `3.0.2-rc10` and `~> 1.16.0`. Roadmap
sub-project 2 fixes the pins and builds the Talos cluster; until then CI
validates only `dev` and `shared`, and nothing here should be extended
without saying so.

> Avoid manual changes to Terraform-managed Proxmox resources; use Terraform for drift-free automation.
>
> Read the plan summary before every apply: an unintended `destroy` is a
> stop. Renaming a module or resource needs a `moved` block — ADR
> [0013](../docs/decisions/0013-terraform-renames-need-moved-blocks.md).

---

## Module Overview

- **modules/lxc** – reusable module for lightweight Proxmox containers; backs the LAN-service LXCs (`module.lan_service`, vmids 140–144) in `environments/shared`, and prod's never-applied containers.
- **modules/nfs-server** – `ubuntu-vm` plus three data disks (`scsi1` for `nfs-dev`, `scsi2` for `nfs-prod`, `scsi3` for `nfs-backups`); backs `nfs-01` (vmid 103) in `environments/shared`.
- **modules/vault-vm** – `ubuntu-vm` plus one data disk for Vault's raft store; backs `vault-02` (vmid 105) in `environments/shared`.
- **modules/ubuntu-vm** – baseline Ubuntu VM provisioning with cloud-init.
- **modules/talos-vm** / **modules/talos-k8s** – Talos OS VM modules for Kubernetes control-plane and worker roles; used only by the never-applied prod root.
- **modules/ubuntu-k8s** – Ubuntu-based Kubernetes nodes via kubeadm.
- Additional modules can be added under `modules/` and referenced from environment `main.tf` files.
