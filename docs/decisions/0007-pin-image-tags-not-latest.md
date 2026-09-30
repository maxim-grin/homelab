# 0007. Pin image tags, never `:latest`

**Status:** Accepted (2026-09-15)

## Context

jobboard ran `ghcr.io/maxim-grin/jobboard:latest`, the only image in the
repository still on a mutable tag. Reverting the Deployment left `:latest`
pointing at `:latest` — there was no prior state to return to, and
`docs/rebuild.md` documented an ordering trap because of it.

## Decision

Name the version once, in `argocd/apps/jobboard/dev/kustomization.yaml`'s
`images:` transformer (`newTag: "0.1.0"`, quoted so it can't parse as a
float), not in `base/app-deployment.yaml`, which names the image with no
tag at all. `imagePullPolicy` moves from `Always` to `IfNotPresent`, safe
because an immutable tag never resolves to different content. The version
is not duplicated into an `app.kubernetes.io/version` label, which would be
a second place to drift.

## Consequences

`git log` on the overlay's `kustomization.yaml` is now dev's deploy history,
one line per release, and rollback is the same edit with the previous
number — which now actually works. Deploying is a real change ArgoCD
rolls on its next poll rather than a no-op. Naming a version that has not
been published yet gives `ImagePullBackOff` until it is, which is loud and
self-correcting rather than silent.

## Related

`docs/superpowers/specs/2026-09-15-jobboard-version-pinning-design.md`;
[#14](https://github.com/maxim-grin/homelab/pull/14); README.md "jobboard
image version".
