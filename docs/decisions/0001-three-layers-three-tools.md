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
workloads and the `argocd/base/projects.yaml` AppProject. Ansible still
bootstraps the plumbing ArgoCD itself needs before it can take over: the
`argocd` role Helm-deploys ArgoCD and creates the `cmp-plugin` ConfigMap
and `argocd-vault-plugin-config` Secret it needs to start,
`cluster_secrets` creates the Secrets ArgoCD's Applications expect to
find already in place, and `coredns_hosts.yaml` pins names ArgoCD-managed
workloads resolve. Past that bootstrap, Kubernetes workloads are ArgoCD's
alone.

## Consequences

Each layer has its own moment of "taking effect": Terraform and Ansible
immediately, ArgoCD only after a merge to `main` and its next poll
(~3 min). Mixing up which layer a change belongs to wastes an afternoon.
The four-row table in CLAUDE.md ("How a change reaches the cluster")
exists specifically to keep this straight.

## Related

CLAUDE.md, "How a change reaches the cluster"; README.md, "What actually
runs" table.
