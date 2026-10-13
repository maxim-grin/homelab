# 0030. Apps can opt in to server-side diff

**Status:** Accepted (2026-10-12)

## Context

`prod-jobboard` read `OutOfSync` for good, on `StatefulSet/postgres` only,
while `dev-jobboard`, from the same base, was clean. Argo's diff showed
`creationTimestamp: null` under `volumeClaimTemplates[].metadata` on one
side only. A server-side dry run of the rendered manifest against prod
(`kubectl diff --server-side --field-manager=argocd-controller
--force-conflicts`) changed nothing under `volumeClaimTemplates`, so the
object was right and the comparison was not. The ApplicationSet gave every
app `ServerSideApply=true` for syncing but never `ServerSideDiff`, so the
controller compared client-side. A manifest change to match the stored
field (#143) could not be shown to help and was closed.

## Decision

**An entry in an app's `config.yaml` can set `serverSideDiff: true`.** The
set's `templatePatch` then puts the annotation
`argocd.argoproj.io/compare-options: ServerSideDiff=true` on the generated
Application, so Argo compares the way it applies. The key is optional and
off by default; only `prod-jobboard` sets it. `scripts/check-appsets.sh`
fails a config that sets it when the patch does not read it.

Rejected:

- **`ignoreDifferences` on the claim template**: hides the field and
  anything else that later changes there.
- **Turning it on for every app**: the template is shared by all prod
  apps, and the others show no drift.
- **Another manifest edit to the StatefulSet**: the dry run says the
  manifest already matches.

## Consequences

- The cause of the prod/dev difference is not established: dev's live
  claim template carries the stored `creationTimestamp: null` and prod's
  does not. The comment in `postgres-statefulset.yaml` about what the
  `apiVersion` and `kind` lines fix is from before this and is unverified.
- Whether the hub's Argo version honors the annotation is unconfirmed
  until the first sync: `argocd app get prod-jobboard` should read
  `Synced`. If it does not, revert the one config key.
- The CLI's `--server-side-diff` fails against this server
  (`unknown method ServerSideDiff`); that RPC is not the controller's.

## Related

Records [0026](0026-uniform-apps.md),
[0029](0029-jobboard-migrates-in-an-init-container.md).
