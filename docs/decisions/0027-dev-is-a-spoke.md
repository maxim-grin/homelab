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
  playbook re-run.
- The hub holds a credential for dev (`argocd-manager`, cluster-admin);
  losing the hub's Vault read loses the ability to deploy to dev.
- Adoption is staged in several PRs, each verified before the next.

## Related

`docs/superpowers/specs/2026-10-05-dev-spoke-design.md`; records
[0004](0004-secrets-in-vault-via-avp.md),
[0024](0024-hub-in-prod.md),
[0026](0026-uniform-apps.md).
