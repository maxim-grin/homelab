# 0036. metrics-server on prod verifies the kubelets it scrapes

**Status:** Accepted (2026-11-28)

## Context

Prod had no Metrics API: `kubectl top nodes` answered `error: Metrics API not
available`. A kubelet signs its own serving certificate unless told to
request one from the cluster CA, so metrics-server cannot verify it. Once
told, the kubelet files a certificate request that Kubernetes does not
approve by itself.

## Decision

**Prod runs metrics-server with certificate checks on, both ways.** Talos
sets `serverTLSBootstrap: true` in every node's `KubeletConfig`
(`terraform/environments/prod/talos.tf`). The
`kubelet-serving-cert-approver` app (upstream release 0.12.1, manifest copied
in, image pinned by tag and digest) approves the requests;
kube-controller-manager signs them. cert-manager issues the certificate the
API server verifies metrics-server with.

Rejected:

- **`--kubelet-insecure-tls`**: needs no Talos change, but no kubelet
  certificate is checked.
- **`insecureSkipTLSVerify: true` on the APIService**: the API server would
  not check who answers the Metrics API.
- **Talos installing the approver at bootstrap**: no gap on a rebuild, but
  the app would sit outside ArgoCD. The gap is documented instead.
- **prometheus-adapter**: reuses Prometheus and needs no Talos change, but
  has more rules to maintain.

## Consequences

The effects on a node are expected from reading the Talos and provider
source, not proven by a live run.

- The approver is now needed for `logs`, `exec`, `port-forward` and
  Prometheus kubelet scrapes: for a new node, and again at every certificate
  renewal. While a node's request is unapproved, all four fail for that node.
  It runs one replica.
- It approves kubelet serving requests from every node, with no person
  looking. kube-controller-manager signs what it approves.
- Applying the patch should not reboot a node (the provider's `apply_mode`
  is `auto`, which should take this change without one). The kubelet restarts
  and drops its self-signed certificate at once, so the approver must be
  healthy first
  ([Turn on kubelet serving certificates](../runbooks/playbooks-and-terraform.md#turn-on-kubelet-serving-certificates)).
- After the merge, **any untargeted `terraform apply` in `environments/prod`
  pushes the patch to all three nodes**, including one meant for something
  else, such as a node resize.
- On a rebuild from nothing the patch is applied before ArgoCD exists. Until
  the approver syncs, `logs` and `exec` fail, also for debugging ArgoCD, and
  `talosctl health` may stall. The way out is
  [approving by hand](../runbooks/checks.md#approve-a-kubelet-serving-certificate-by-hand).
- Renovate moves the chart and image versions, but not the copied upstream
  manifest. When the approver's image tag or digest moves, compare
  `standalone-install.yaml` with that release's manifest.

## Related

Builds on [0021](0021-talos-prod-via-terraform-provider.md).
