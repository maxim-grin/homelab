# 0027. Dev is a spoke of the prod hub, adopted in place

**Status:** Accepted (2026-10-09)

## Context

Dev ran standalone: its own ArgoCD (`dev-argocd.mgryn.cc`) watching
`argocd/environments/dev`, Applications written in the pre-uniform
shapes, and a hand-rolled monitoring stack with its own Prometheus and
Grafana. Prod has had the hub since [0024](0024-hub-in-prod.md), and
[0026](0026-uniform-apps.md) made every app a directory the one
ApplicationSet can deploy to any registered cluster. Two ArgoCDs and two
monitoring stacks double the surfaces to watch for one operator.

## Decision

**Dev is a spoke.** The prod hub deploys to dev. Dev's Applications are
the existing `apps` set's outputs, named `dev-<dir>`; there is no second
set and no dev-specific Application file.

**Adopted in place.** Dev's Applications drop their
`resources-finalizer` in git first (`root-dev`'s selfHeal restores a
hand-patched one), dev's own application controller is stopped, the
hub's `dev-*` Applications take over the live resources, and dev's
ArgoCD is uninstalled without cascade. Nothing is recreated: jobboard
stays up with its database.

**Monitoring is the one exception.** Dev's hand-rolled Prometheus and
Grafana are torn down, and an agent-mode Prometheus Operator install
(`kube-prometheus-stack/dev`), remote-writing to the hub, is created
fresh. It is not adopted, because the old stack has no counterpart to
adopt into.

**A cluster Secret per spoke, rendered by its own Application.**
`argocd/apps/clusters/dev/` holds `cluster-dev` (label `env: dev`,
`name: dev`), whose address, bearer token and CA are AVP placeholders
for `kv-prod/argocd/clusters/dev`, written by
`ansible/playbooks/dev_register.yaml`. The `clusters-dev` Application
renders it through the argocd-vault-plugin. Prod's `clusters`
Application stays plain, so the prod cluster list never depends on Vault
being unsealed: a sealed Vault leaves only the dev Secret un-rendered.

**The hub's `kv-dev/` read is not re-decided.** [0026](0026-uniform-apps.md)
already gave the hub's policy `kv-dev/` (`extra_kv_mounts`); the
AppProject already allows destination `name: dev`.

Rejected:

- **Cascade-delete and recreate**: deleting dev's Applications with
  their finalizers takes jobboard down, and its database exists only in
  the dump. It is the fallback, not the plan.
- **Keep dev standalone**: two ArgoCDs and two monitoring stacks stay.
- **Dev's cluster Secret in the plain `clusters` Application**: a sealed
  Vault would break the prod cluster list, and with it the set's
  Applications for prod.

## Consequences

- One ArgoCD shows both clusters; adding an app to dev is an
  `- env: dev` entry in its `config.yaml`.
- A sealed Vault leaves `clusters-dev` `Unknown`. The hub then keeps
  the last-rendered Secret; a rebuilt dev needs the registration
  playbook re-run, then a hard refresh of `clusters-dev`: the
  repo-server caches the render by git revision and a Vault write does
  not change it. Run the playbook before merging the PR that adds the
  Secret, or `clusters-dev` shows a `ComparisonError` until it runs.
- The hub holds a credential for dev (`argocd-manager`, cluster-admin);
  losing the hub's Vault read loses the ability to deploy to dev.
- Adoption is staged in several PRs, each verified before the next.
- Dev was then replaced by a smaller cluster, `kubeadm-dev` (one control
  plane, one worker, `cluster_id` 4, vmids 4101 and 4201), with the old
  one destroyed first because host RAM is fully committed (a targeted
  destroy, then the apply; one plain apply would start both sets at
  once). A rebuilt dev is registered with the hub again (new CA and
  token). The worker joins as `worker-01` (its inventory name)
  while its VM is `kubeadm-dev-w1`; that mismatch is accepted.

## Related

Records
[0004](0004-secrets-in-vault-via-avp.md),
[0024](0024-hub-in-prod.md),
[0026](0026-uniform-apps.md).
