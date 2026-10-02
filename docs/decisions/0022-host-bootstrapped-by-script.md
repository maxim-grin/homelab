# 0022. Proxmox host bootstrapped by one script

**Status:** Accepted (2026-10-01)

## Context

Everything under the Terraform environments, the repositories, users, API
token, pools, ACLs and three VM or container templates, was forty-odd
hand-typed commands in `docs/rebuild.md`. The Ubuntu and Talos template
builds repeated the same import-and-convert sequence, and a rebuild after
an SSD failure meant pasting them in the right order on a host with
nothing on it yet.

## Decision

One standalone bash script, `scripts/pve-bootstrap.sh`, runs on the new
host as root with nothing but the file itself. It is a list of named steps
(`repos`, `users`, `pools`, `lxc-template`, `ubuntu-template`,
`talos-template`), each of which checks what exists before changing it, so
a second run creates nothing: it only sets the `TerraformProv`
privilege list again (reported as changed), and every other step reports
skipped. Every mutating command goes through one
`run` wrapper, which is what makes `--dry-run` print instead of act.

Secrets are never written to a file or logged: the admin password is read
from the terminal and piped to `chpasswd`, `terraform@pve` has no password,
and the API token secret is printed once, when Proxmox shows it, for the
operator to copy. The script never destroys a template; rebuilding one is
`qm destroy` by hand and a re-run. The Talos version and schematic are
constants in the script, and CI checks them against the defaults in the
prod root (`scripts/check-talos-pins.sh`). CI also runs `shellcheck` and
stub-based tests (`scripts/tests/pve-bootstrap.test.sh`).

Rejected: an Ansible role, which needs SSH access and an inventory entry
for a host that has neither yet; the `bpg/proxmox` Terraform provider, a
second provider against one host that cannot build a template from a
downloaded image; and reading the Talos pins from `variables.tf` at run
time, which would make a standalone script depend on a checkout.

## Consequences

The stubs prove that the steps are idempotent and call the commands in the
right order, not that real `pveum` and `pveam` output matches what the
script parses. The first real run on a host is the final test. The script
and `terraform/environments/prod/variables.tf` must change together when
Talos is upgraded, and CI fails if they do not. Sections 1, 2 and 2b of
`docs/rebuild.md` now keep the reasons and leave the commands to the
script.

## Related

`docs/superpowers/specs/2026-10-01-pve-bootstrap-design.md`; ADR
[0021](0021-talos-prod-via-terraform-provider.md).
