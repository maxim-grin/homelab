# Proxmox Terraform Setup

![img.png](../img.png)

The infrastructure is devided into development and production environment. The repository follows a standard Terraform module layout:

```txt
proxmox/
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
│   └── prod/
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
cp proxmox/environments/dev/dev.tfvars.example proxmox/environments/dev/dev.tfvars
# then fill in pm_api_token_id, pm_api_token_secret, the SSH key paths and
# the cloud-init password by hand

cp proxmox/environments/dev/backend.tf.example proxmox/environments/dev/backend.tf
# local backend, state file next to main.tf -- nothing to fill in
```

`backend.tf` is gitignored alongside `*.tfvars`, for the same reason: it is
a per-checkout file, not a secret, but keeping it out of git means every
checkout copies it from the committed `.example` once. State itself is
local (`terraform.tfstate` next to `main.tf`), not a remote backend, so
there is no bucket or credential involved in either file.

---

## Initialising an Environment

```bash
cd proxmox/environments/dev   # swap dev for prod when needed
terraform init
```

There is no remote backend to bootstrap. `backend.tf` declares `local`
state, and `terraform init` just needs that file and the providers cached
-- nothing external to prepare first.

---

## Routine Terraform Commands

### Development (Dev)

```bash
cd proxmox/environments/dev
terraform plan  -var-file="dev.tfvars"
terraform apply -var-file="dev.tfvars"
```

### Production (Prod)

```bash
cd proxmox/environments/prod
terraform plan  -var-file="prod.tfvars"
terraform apply -var-file="prod.tfvars"
```

> **Do not** run `terraform destroy` against the production environment.
>
> Avoid manual changes to Terraform-managed Proxmox resources; use Terraform for drift-free automation.

---

## Module Overview

- **modules/lxc** – reusable module for lightweight Proxmox containers; backs `vault-01` (vmid 104) in `environments/dev`.
- **modules/ubuntu-vm** – baseline Ubuntu VM provisioning with cloud-init.
- **modules/talos-vm** / **modules/talos-k8s** – Talos OS VM modules for Kubernetes control-plane and worker roles.
- **modules/ubuntu-k8s** – Ubuntu-based Kubernetes nodes via kubeadm.
- Additional modules can be added under `modules/` and referenced from environment `main.tf` files.
