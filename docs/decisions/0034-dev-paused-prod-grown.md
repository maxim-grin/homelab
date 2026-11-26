# 0034. Dev is paused; prod takes its memory and grows

**Status:** Accepted (2026-11-26)

## Context

The host has 32 GB and every VM is committed: prod's three Talos nodes at
4 GB, `dev`'s two kubeadm nodes at 3 GB each, `claude-code` 4 GB, NFS and
Vault 2 GB each, and five LXCs at 256 MB. The directive-copilot app needs
Postgres with pgvector, Ollama and LiteLLM on prod. Its images alone are
3.4 GB (Ollama), 0.7 GB (LiteLLM) and 0.16 GB (pgvector) compressed, and
`dev`'s node disks were 10 GB when they caused kubelet evictions (see the
comments in `terraform/environments/dev/main.tf`). `dev` also hosts jobboard's
staging role ([0028](0028-jobboard-in-prod.md)), a shortener copy and the
monitoring agent; pausing it stops all three.

Figures come from the Terraform code and `.tfvars.example` files, not
from live `.tfvars` or measured memory use.

## Decision

**`dev` is paused.** Its two VMs (`kubeadm-dev-cp1`, `kubeadm-dev-w1`) are
shut down, with disks and NFS data kept. Their `start_at_node_boot` is
`false`, so a host reboot does not start them. The `dev-*` Applications
and the `clusters-dev` Application are removed from the hub; the
ApplicationSet no longer generates `dev` apps.

**`prod` grows.** Workers go from 4 GB to 7 GB each. The control plane
stays at 4 GB. `node_cores` goes from 2 to 4 for all three nodes, and
`node_disk_size` from 20 GB to 40 GB.

**No staging cluster.** While `dev` is paused, jobboard has no staging
copy. This suspends the dev-first step of
[0028](0028-jobboard-in-prod.md): new tags go straight to prod.

Resource totals stay at 27.25 GB of the 32 GB host, before and after.
The 6 GB that `dev` held is what the two prod workers gain.

Rejected:

- **Grow the `dev` worker.** A disposable cluster takes memory from
  elsewhere and leaves the host under 3 GB.
- **Use the existing `prod` workers as they are.** They are 4 GB, and
  monitoring and jobboard already run on them.
- **A new k3s VM.** Matches the earlier plan, but needs the most memory of
  the three options.

## Consequences

- Resuming `dev` is not a plain revert. Shrink prod first: workers back to
  4096 MB, with cores and disks left at 4 and 40G, since a disk cannot shrink.
  Then restore dev's files only: `dev/main.tf`, `dev/dev.tftest.hcl`, the
  `env: dev` entries and `clusters-dev.yaml`. The `argocd/apps/*/dev/`
  directories and the VM definitions are kept for this. The runbook entry
  "Pause and resume dev" lists the steps.
- Prod's disks and cores are bigger after the next apply, and each node
  restarts to take them (`automatic_reboot = false`, one node at a time).
  The single control plane's restart takes the API down briefly.
- Proxmox cannot shrink a disk, so the 40 GB prod disks are permanent.
- `dev-jobs.mgryn.cc` answers nothing until `dev` returns.
- The memory estimate for the new app is a guess until measured. Node
  memory use is the baseline for the next milestone.
