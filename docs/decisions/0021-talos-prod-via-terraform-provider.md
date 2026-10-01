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
