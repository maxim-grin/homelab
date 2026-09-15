# jobboard Version Pinning — Design

Name a published, immutable jobboard version in the dev overlay instead of
tracking the mutable `:latest` tag.

## Problem

`argocd/apps/jobboard/base/app-deployment.yaml` names
`ghcr.io/maxim-grin/jobboard:latest`. It is the only image in this repository
not pinned to a fixed tag — `postgres:17`, `gitea/gitea:1.22.3-rootless`,
`prom/prometheus:v3.7.0`, `grafana/grafana:11.4.0`,
`registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0` and the
nfs-subdir provisioner all name versions, and harbor and ingress-nginx come from
pinned chart versions. jobboard is the exception because it is the only image
built from a repository we own.

Three consequences follow from the tag being mutable:

**Nothing redeploys.** A new image under the same tag leaves the pod spec
byte-identical, so Kubernetes sees no diff and does not roll. `README.md`
documents `kubectl rollout restart deployment/jobboard -n jobboard` as the
workaround.

**Rollback does not work.** Reverting the Deployment changes `:latest` to
`:latest`. There is no prior state to return to, because the manifest never
recorded one.

**git does not describe what is deployed.** The manifest names a pointer, not a
build, so neither repository records which image is running.

There is also a documented ordering trap in `docs/rebuild.md`: because `:latest`
must already point at the right build, the app repository must be merged and its
`image` job must go green *before* this repository is pushed. Getting it backwards
silently runs the previous image rather than failing.

## Precondition

This design consumes a contract defined by the job-board repository's
`docs/superpowers/specs/2026-09-15-release-tagging-design.md`:

> job-board publishes `ghcr.io/maxim-grin/jobboard:<semver>` when, and only
> when, a `v<semver>` git tag is pushed, and never re-points a published tag.

That repository ships first and cuts `v0.1.0`. This repository cannot name a
version that has not been published, so nothing here can land before it.

**Nothing in the cluster writes to git.** ArgoCD reads this repository, renders,
and applies. Deploying a new version is a human editing one line here.

## Decisions

**The version lives in `argocd/apps/jobboard/dev/kustomization.yaml`, as a
kustomize `images:` transformer, not in `base/app-deployment.yaml`.** The base
describes what the application *is*; the overlay describes what this environment
*runs*. Keeping it there makes
`git log -- argocd/apps/jobboard/dev/kustomization.yaml` a deploy history for
dev, one line per release, rather than mixing deploys into a file that also
changes for probes, resources and environment variables. There is currently only
a dev overlay, so per-environment pinning is not yet load-bearing; the deploy log
is the reason that stands on its own today.

```yaml
images:
  - name: ghcr.io/maxim-grin/jobboard
    newTag: "0.1.0"
```

**`newTag` is quoted.** `newTag: 1.0` parses as a float and renders as
`jobboard:1`. Quoting costs nothing and removes the class.

**The version is not duplicated anywhere else** — notably not into an
`app.kubernetes.io/version` label, which would be two places to bump and would
drift. This repository already documents the same trap for the jobboard database
password, which appears both standalone and inside `DATABASE_URL`.

**`imagePullPolicy` becomes `IfNotPresent`.** The comment above it in
`app-deployment.yaml` currently warns that pinning to a SHA would flip the
default to `IfNotPresent` and "reintroduce the stale-image confusion". That
reasoning inverts once the tag is immutable: staleness is a property of mutable
tags, and an immutable tag cannot resolve to different content. The comment is
rewritten rather than deleted, because the reasoning it records is what a future
reader will otherwise repeat.

**The base keeps naming the image, and its tag is not maintained.** The
transformer overrides it for everything actually deployed, and `base/` is never
applied on its own. Maintaining a second version string there is the duplication
ruled out above.

## Interaction with argocd-vault-plugin

jobboard's Application sets `spec.source.plugin.name: argocd-vault-plugin`, so
ArgoCD delegates manifest generation to the CMP sidecar, whose `generate`
command runs `kustomize build .` for an overlay. The `images:` transformer is
part of kustomize and runs inside that build, so the pin takes effect on the
plugin path exactly as it would on the plain one. Verified against the live
overlay: an `images:` block rewrites the jobboard tag and leaves `postgres:17`
untouched, since the transformer matches by image name.

## Documentation this removes

- `README.md`'s `kubectl rollout restart` section goes entirely. It exists only
  to work around the mutable tag.
- `docs/rebuild.md`'s merge-order caveat is rewritten rather than deleted. The
  ordering still matters, but the failure changes character: naming a version
  that is not yet published gives `ImagePullBackOff` until it is, which is loud
  and self-correcting, instead of silently running the previous build.

## Deploying, once this lands

```
vim argocd/apps/jobboard/dev/kustomization.yaml    # newTag: "0.2.0"
git commit && git push
```

ArgoCD syncs within about three minutes. The pod spec genuinely changed, so it
rolls on its own. Rolling back is the same edit with the previous number.

## Explicitly out of scope

- **Automatic image updates.** `argocd-image-updater` with git write-back was
  the alternative and is rejected: it needs a Deployment, a chart repository in
  the AppProject's `sourceRepos`, and a repository-write GitHub PAT living as a
  Secret in the `argocd` namespace — where anything able to read a Secret can
  push to `main` — to serve the one image here not already pinned. The
  `2026-09-10-image-updater.md` plan was deleted; the reasoning is recorded in
  `docs/superpowers/specs/2026-09-10-vault-avp-design.md` under Out of scope.
- **Automatic dependency bumping** for the other seven pinned images. Renovate
  or Dependabot would open pull requests against this repository and would cover
  postgres and grafana as well as jobboard, leaving ArgoCD read-only. That is a
  separate decision and a separate design.
- **A prod overlay.** `proxmox/environments/prod` and `talos/` remain untouched
  scaffolding.
