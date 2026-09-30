# 0009. CI only reads, and any lint finding fails the build

**Status:** Accepted (2026-09-20)

## Context

Nothing ran the repository's checks automatically: `.pre-commit-config.yaml`
executed locally only, so `--no-verify` or a fresh clone skipped it, and
nothing ran `terraform validate`, `kustomize build` or `helm template` at
all before a merge. Merge to `main` is the deploy, so the point of CI is
to catch what would otherwise break in ArgoCD or leak a secret, before
merge.

## Decision

Four parallel GitHub Actions jobs on every PR and push to `main` —
`pre-commit` (the same hooks plus a full-history gitleaks scan),
`commits` (conventional-commit check on PRs), `terraform` (`init
-backend=false`, `validate`, `tflint`), `manifests`
(`scripts/check-manifests.sh`: kustomize/helm render + `kubeconform
-strict`). Nothing in CI touches the cluster, Proxmox, or any secret — it
only reads. Alongside it, every existing `ansible-lint` finding was cleared
and `ansible/.ansible-lint-ignore` deleted, so the hook runs at profile
`production` with no ignore file and any new finding fails it.

## Consequences

The ignore file had been hiding real bugs — `base_setup` called
`ansible.builtin.modprobe`/`sysctl`, modules that do not exist. Green CI is
now the floor: it renders and schema-checks manifests, it does not prove
anything serves traffic. CI runs `validate`, never `plan`, so a Terraform
rename missing a `moved` block still passes (record
[0013](0013-terraform-renames-need-moved-blocks.md)). Branch protection
requiring the four checks is a manual, one-time repository setting, not
tracked in git.

## Related

`docs/superpowers/specs/2026-09-20-ci-design.md`;
[#26](https://github.com/maxim-grin/homelab/pull/26)-[#28](https://github.com/maxim-grin/homelab/pull/28);
README.md "Checks before committing" and "CI".
