# 0001. Three layers, three tools

**Status:** Accepted (2026-09-08)

## Context

The homelab has three kinds of state to change — the VMs and disks
themselves, the OS and cluster software on them, and the workloads running
in Kubernetes — and each has its own natural tool: Terraform for
provisioning, Ansible for configuration, ArgoCD for delivery.

## Decision

Keep the three layers strictly separate, each applied by exactly one tool:
Terraform (`terraform apply` in `environments/dev` or `environments/shared`)
for VMs, disks and network; Ansible (`ansible-playbook`) for OS, packages
and the kubeadm cluster; ArgoCD, syncing `main` from GitHub, for Kubernetes
workloads and the `argocd/base/projects.yaml` AppProject. No tool reaches
into another's layer — Ansible does not template Kubernetes manifests, and
ArgoCD does not touch the OS.

## Consequences

Each layer has its own moment of "taking effect": Terraform and Ansible
immediately, ArgoCD only after a merge to `main` and its next poll
(~3 min). Mixing up which layer a change belongs to is the most common way
a session wastes time — editing a Kubernetes manifest and expecting
`ansible-playbook` to apply it, or changing a role and expecting ArgoCD to
pick it up. The three-row table in CLAUDE.md ("How a change reaches the
cluster") exists specifically to keep this straight.

## Related

CLAUDE.md, "How a change reaches the cluster"; README.md, "What actually
runs" table.
