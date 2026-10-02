# 0017. Every LAN-service binary is verified by SHA-256

**Status:** Accepted (2026-09-28)

## Context

The LAN services roles (record [0014](0014-lan-services-as-lxcs.md))
install software by downloading a release archive, binary or container
image directly from its publisher, rather than through a distro package
repository — nothing else in the repository's Ansible roles verified a
download this way before.

## Decision

Every role pins its version in `defaults/main.yaml` and verifies a
SHA-256 before installing, from whichever source the publisher actually
gives: Traefik's published checksums file; GitHub's per-asset digest for
Glance and LAN Orangutan, which publish no checksums file at all; and for
Gatus, which publishes only container images, the digest of the image
layer holding its binary — a registry blob's digest is the SHA-256 of its
bytes, so `get_url`'s `checksum` parameter verifies it exactly like a
release checksum. Pi-hole is the one exception, installed by its own
official installer.

## Consequences

Each of these facts had to be established and checked by hand while
planning — the Gatus image layer digest, and the Glance and LAN Orangutan
per-asset digests were each verified against a real downloaded file before
being committed. A version bump means finding and pinning a new digest,
not just a new version string; get that step wrong and the role fails
loudly at download rather than installing something unverified. Roles
written before the LAN services — `vault`, `kube_packages`, `workstation`,
and the AVP binary `curl`'d in `roles/argocd` — still fetch their
downloads with no checksum verification at all.

## Update (2026-10-01): CI downloads follow the same rule

`.github/workflows/ci.yaml` fetched gitleaks, kustomize, kubeconform and
yq with `curl` and no verification, in a job that holds a repository
checkout. Each now has a `*_SHA256` next to its `*_VERSION` in the
workflow's `env` block, taken from GitHub's per-asset digest, and
`sha256sum --strict -c` checks the download before it is unpacked.
`--strict` matters: without it GNU `sha256sum` exits 0 on a malformed
checksum line, such as an empty variable. A version bump there needs a
new digest as well, with the `gh api` command in the workflow's comment.

## Related

`docs/superpowers/specs/2026-09-27-lan-services-design.md` "Ansible";
`docs/superpowers/plans/2026-09-28-lan-services-apps.md` "Facts established
while planning"; `ansible/roles/traefik`, `ansible/roles/gatus`.
