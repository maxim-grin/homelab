# 0034. Dev is destroyed; prod takes its memory and grows

**Status:** Accepted (2026-11-26)

## Context

The host has 32 GB and every VM is committed: prod's three Talos nodes at
4 GB, `dev`'s two kubeadm nodes at 3 GB each, `claude-code` 4 GB, NFS and
Vault 2 GB each, and five LXCs at 256 MB. The directive-copilot app needs
Postgres with pgvector, Ollama and LiteLLM on prod. Its images alone are
3.4 GB (Ollama), 0.7 GB (LiteLLM) and 0.16 GB (pgvector) compressed, and
10 GB node disks caused kubelet evictions on `dev`. `dev` also held
jobboard's staging role ([0028](0028-jobboard-in-prod.md)), a shortener copy
and the monitoring agent; losing it stops all three. The owner's call:
nothing on `dev` is worth keeping.

Figures come from the Terraform code and `.tfvars.example` files, not
from live `.tfvars` or measured memory use.

## Decision

**`dev` is destroyed.** The `kubeadm-dev` module leaves
`terraform/environments/dev`, so the next apply there destroys its two VMs,
`kubeadm-dev-cp1` (vmid 4101) and `kubeadm-dev-w1` (vmid 4201), with their
disks. The `dev-*` Applications and the `clusters-dev` Application are
removed from the hub. `claude-code` stays in the same Terraform root.
Variables, the `ubuntu-k8s` module, the dev Ansible files and
`argocd/apps/*/dev/` stay, so a rebuild is a restore from git.

**`prod` grows.** Workers go from 4 GB to 7 GB each. The control plane
stays at 4 GB. `node_cores` goes from 2 to 4 for all three nodes, and
`node_disk_size` from 20 GB to 40 GB.

**No staging cluster.** jobboard has no staging copy. This suspends the
dev-first step of [0028](0028-jobboard-in-prod.md): new tags go straight to
prod.

Resource totals stay at 27.25 GB of the 32 GB host, before and after.
The 6 GB that `dev` held is what the two prod workers gain.

Rejected:

- **Shut `dev` down and keep its disks.** Holds disk space and needs its own
  pause and resume procedure, for data nobody wants.
- **Grow the `dev` worker.** A disposable cluster takes memory from
  elsewhere and leaves the host under 3 GB.
- **Use the existing `prod` workers as they are.** They are 4 GB, and
  monitoring and jobboard already run on them.
- **A new k3s VM.** Matches the earlier plan, but needs the most memory.

## Consequences

- `terraform/environments/dev` holds only `claude-code`, so an untargeted
  apply there is safe. `terraform destroy` there would destroy the
  workstation.
- A rebuild shrinks prod first (workers back to 4096 MB; cores and disks
  stay, since a disk cannot shrink), then restores dev's files from git. The
  runbook entry "Rebuild dev" lists the steps. Volumes start empty.
- The old cluster's volume directories stay on `nfs-01` under
  `/srv/nfs/k8s`, and `nfs-01` still exports it to the old node addresses.
- Prod's disks and cores are bigger after the next apply, and each node
  restarts to take them (`automatic_reboot = false`, one node at a time).
  The single control plane's restart takes the API down briefly.
- Proxmox cannot shrink a disk, so the 40 GB prod disks are permanent.
- `dev-jobs.mgryn.cc` answers nothing.
- The memory estimate for the new app is a guess until measured. Node
  memory use is the baseline for the next milestone.
