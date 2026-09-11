# ArgoCD Image Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the jobboard app repo publishes a new `:latest` image, the cluster picks it up on its own instead of waiting for a manual `kubectl rollout restart`.

**Architecture:** `argocd-image-updater` runs in the `argocd` namespace, deployed as an ArgoCD Application from the `argo-helm` chart repository. It watches the digest behind the mutable `latest` tag and, on a change, commits the new digest back to this repository; ArgoCD then syncs that commit like any other. Registry and git credentials both come from Vault through AVP, so neither is applied by hand.

**Tech Stack:** `argocd-image-updater` Helm chart from `https://argoproj.github.io/argo-helm`, argocd-vault-plugin, GHCR.

**Spec:** `docs/superpowers/specs/2026-09-10-vault-avp-design.md` (Layer 6 and its entries in Documentation changes)

**Order:** Requires BOTH other plans landed first —
`2026-09-10-argocd-selfmanagement-ingress.md` for the self-managing AppProject
that whitelists the chart repository, and `2026-09-10-vault-avp.md` for the AVP
sidecar that renders this plan's two credentials.

## Global Constraints

- **ArgoCD syncs `main` from GitHub, not the working copy.** A commit is not a deploy.
- Branch before the first commit. `main` receives finished work as a merge.
- Conventional Commits. Subject <= 50 chars, imperative, lowercase, no trailing period. Body wrapped at 72. Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `ops`.
- **No `Co-Authored-By` trailer and no generated-with footer.**
- ArgoCD reads a **public** repository. `<path:...>` placeholders are committed; values never are.
- A new Helm chart repository must be in the AppProject's `sourceRepos`, or ArgoCD refuses the Application with "application repo is not permitted".
- `argocd/apps/harbor/dev` and `argocd/apps/ingress-nginx/dev` hold only `values.yaml`; `kustomize build` on them fails by design. This plan adds a third such directory.
- No test suite. Verification is tool checks plus inspecting the cluster.
- Steps marked **[operator]** need cluster or password-manager access an agent does not have.

---

### Task 1: Git write-back credentials in Vault

**Files:**
- Modify: `ansible/secret.yaml` (the `vault_kv` block) **[operator]**
- Modify: `ansible/secret.yaml.example`
- Create: `argocd/base/git-creds.yaml` (committed, placeholders only)

**Interfaces:**
- Consumes: the AVP sidecar from `2026-09-10-vault-avp.md` Task 5, and the `argocd-config` Application from the self-management plan, which syncs `argocd/base/`.
- Produces: a Secret `git-creds` in namespace `argocd` holding a GitHub username and PAT. Task 3's `write-back-method` annotation names it.

**The credential's blast radius, stated plainly:** this is a write token for a
public repository. AVP delivers it so it costs no manual step, but anything
that can read Secrets in the `argocd` namespace can push to `main`. Scope the
PAT to this repository only — a fine-grained PAT with `Contents: Read and
write` on `maxim-grin/homelab` and nothing else.

- [ ] **Step 1: Mint the PAT**

GitHub → Settings → Developer settings → Fine-grained tokens. Repository access: only `maxim-grin/homelab`. Permissions: `Contents: Read and write`. Nothing else. **[operator]**

- [ ] **Step 2: Add it to the seed data**

```bash
cd ansible
ansible-vault edit secret.yaml
```

Extend the existing `vault_kv` block:

```yaml
  argocd/git:
    username: "maxim-grin"
    password: "<the fine-grained PAT>"
```

Mirror the structure in `secret.yaml.example` with fake values. **[operator]**

- [ ] **Step 3: Re-seed Vault**

```bash
ansible-playbook playbooks/vault.yaml -e @secret.yaml --ask-vault-pass \
  -e vault_seed=true -e vault_token=<root token>
```

Verify on vault-01:

```bash
vault kv get secret/argocd/git
```

**[operator]**

- [ ] **Step 4: Write the placeholder Secret**

`argocd/base/git-creds.yaml`:

```yaml
# Values come from Vault at sync time via argocd-vault-plugin. Committed to a
# public repository on purpose: the placeholders name paths, not secrets.
# This Secret lets argocd-image-updater push digest updates back to main.
apiVersion: v1
kind: Secret
metadata:
  name: git-creds
  namespace: argocd
type: Opaque
stringData:
  username: <path:secret/data/argocd/git#username>
  password: <path:secret/data/argocd/git#password>
```

- [ ] **Step 5: Route argocd/base through the plugin**

`argocd/base/` now contains a manifest with `<path:...>` placeholders, so the `argocd-config` Application needs the plugin too. In `argocd/environments/dev/applications/argocd-config.yaml`, under `spec.source`:

```yaml
    plugin:
      name: argocd-vault-plugin
```

- [ ] **Step 6: Commit and push**

```bash
git add argocd/base/git-creds.yaml ansible/secret.yaml ansible/secret.yaml.example \
        argocd/environments/dev/applications/argocd-config.yaml
git commit -m "feat(argocd): store git write-back credentials in vault"
git push
```

- [ ] **Step 7: Verify the Secret rendered**

```bash
kubectl -n argocd get secret git-creds -o jsonpath='{.data.username}' | base64 -d ; echo
```

Expected: `maxim-grin`, **not** the literal string `<path:secret/data/argocd/git#username>`. A literal placeholder means the Application is not going through the plugin — re-check step 5. **[operator]**

---

### Task 2: Deploy argocd-image-updater

**Files:**
- Create: `argocd/apps/image-updater/dev/values.yaml`
- Create: `argocd/environments/dev/applications/image-updater.yaml`
- Modify: `argocd/base/projects.yaml` (only if the self-management plan's Task 1 Step 6 did not already add the repo)

**Interfaces:**
- Consumes: the `homelab` AppProject with `https://argoproj.github.io/argo-helm` in `sourceRepos`, and the `ghcr` Secret in namespace `jobboard` created by `2026-09-10-vault-avp.md` Task 6.
- Produces: a running `argocd-image-updater` Deployment in namespace `argocd`. Task 3 drives it with annotations.

- [ ] **Step 1: Confirm the chart repository is allowed**

```bash
kubectl -n argocd get appproject homelab -o jsonpath='{.spec.sourceRepos}' ; echo
```

Expected: includes `https://argoproj.github.io/argo-helm`. If missing, add it to `argocd/base/projects.yaml` and push — the AppProject is self-managing now, so no `kubectl apply`. Without it the Application is refused with "application repo is not permitted". **[operator]**

- [ ] **Step 2: Write the chart values**

`argocd/apps/image-updater/dev/values.yaml` — a Helm inputs directory like `harbor/dev` and `ingress-nginx/dev`, so `kustomize build` on it fails by design:

```yaml
config:
  # Poll GHCR on this interval. The registry is the only thing being polled;
  # git write-back happens only when a digest actually changes.
  argocd:
    # image-updater talks to the Kubernetes API rather than the ArgoCD API,
    # so it needs no ArgoCD auth token. Applications are read as CRs.
    applicationsAPIKind: kubernetes

  registries:
    - name: ghcr
      api_url: https://ghcr.io
      prefix: ghcr.io
      ping: false
      # Reuse the pull Secret AVP already renders for jobboard rather than
      # storing the same PAT twice.
      credentials: pullsecret:jobboard/ghcr

# Needs to read Secrets in the jobboard namespace for the pull secret above,
# and to read and patch Applications in argocd.
rbac:
  enabled: true

resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    memory: 256Mi
```

- [ ] **Step 3: Write the Application**

`argocd/environments/dev/applications/image-updater.yaml`, following the two-source shape `harbor.yaml` already uses for chart-plus-values:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: image-updater
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: homelab
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argocd-image-updater
      targetRevision: 0.12.4
      helm:
        releaseName: argocd-image-updater
        valueFiles:
          - $values/argocd/apps/image-updater/dev/values.yaml
    - repoURL: https://github.com/maxim-grin/homelab.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
  revisionHistoryLimit: 3
```

- [ ] **Step 4: Render the chart locally before pushing**

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm template argocd-image-updater argo/argocd-image-updater \
  --version 0.12.4 -f argocd/apps/image-updater/dev/values.yaml | head -40
```

Expected: manifests render with no schema errors. If a key is rejected, the chart's value names have moved — check `helm show values argo/argocd-image-updater --version 0.12.4`.

- [ ] **Step 5: Commit and push**

```bash
git add argocd/apps/image-updater argocd/environments/dev/applications/image-updater.yaml
git commit -m "feat(argocd): deploy argocd-image-updater"
git push
```

- [ ] **Step 6: Verify it is running and can reach GHCR**

```bash
kubectl -n argocd get application image-updater
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-image-updater
kubectl -n argocd logs deploy/argocd-image-updater --tail=40
```

Expected: `Synced`/`Healthy`, pod `Running`, and logs showing it started and found 0 applications to consider — no annotations exist yet, so 0 is correct here. Authentication errors against ghcr.io mean the `pullsecret:jobboard/ghcr` reference is wrong. **[operator]**

---

### Task 3: Track the jobboard digest

**Files:**
- Modify: `argocd/environments/dev/applications/jobboard.yaml` (annotations)
- Modify: `argocd/apps/jobboard/base/app-deployment.yaml` (the comment about the manual workaround)

**Interfaces:**
- Consumes: the running updater from Task 2 and the `git-creds` Secret from Task 1.
- Produces: a `.argocd-source-jobboard.yaml` file written by the updater into `argocd/apps/jobboard/dev/`, and digest-pinned deployments.

**What write-back actually does to this repo:** for a kustomize application,
image-updater does not edit `app-deployment.yaml`. It writes a sibling file,
`argocd/apps/jobboard/dev/.argocd-source-jobboard.yaml`, holding a kustomize
image override, and commits *that*. Expect it in `git log` under the PAT's
identity, and do not hand-edit it.

- [ ] **Step 1: Add the annotations**

In `argocd/environments/dev/applications/jobboard.yaml`, under `metadata.annotations`:

```yaml
  annotations:
    argocd-image-updater.argoproj.io/image-list: jobboard=ghcr.io/maxim-grin/jobboard
    # digest, not semver: the app repo publishes a mutable :latest tag, so
    # the tag never changes and ArgoCD sees no diff. Tracking the digest
    # behind the tag is what makes a rebuild visible.
    argocd-image-updater.argoproj.io/jobboard.update-strategy: digest
    argocd-image-updater.argoproj.io/jobboard.allow-tags: regexp:^latest$
    argocd-image-updater.argoproj.io/jobboard.pull-secret: pullsecret:jobboard/ghcr
    # git write-back, so this repository keeps describing what is deployed.
    # The alternative writes an annotation into the cluster instead, and a
    # rebuild would then silently revert to whatever :latest resolved to.
    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/git-creds
    argocd-image-updater.argoproj.io/git-branch: main
```

- [ ] **Step 2: Commit and push**

```bash
git add argocd/environments/dev/applications/jobboard.yaml
git commit -m "feat(jobboard): track the image digest"
git push
```

- [ ] **Step 3: Watch it pick the application up**

```bash
kubectl -n argocd logs deploy/argocd-image-updater --tail=40
```

Expected: it now reports 1 application considered, and logs the digest it resolved for `ghcr.io/maxim-grin/jobboard:latest`. **[operator]**

- [ ] **Step 4: Prove write-back end to end**

The acceptance test. Push a trivial change to the **app** repo's `main`, wait for its `image` CI job to publish a new `:latest`, then:

```bash
kubectl -n argocd logs deploy/argocd-image-updater --tail=60 | grep -i 'commit\|digest'
git -C /home/ubuntu/homelab fetch && git log origin/main --oneline -3
ls -a argocd/apps/jobboard/dev/
kubectl -n jobboard get pods -o jsonpath='{.items[*].spec.containers[*].image}' ; echo
```

Expected: a commit on `origin/main` authored by the PAT identity, a
`.argocd-source-jobboard.yaml` in the dev overlay, and the running pod's image
pinned to `ghcr.io/maxim-grin/jobboard@sha256:...` rather than `:latest`. **[operator]**

- [ ] **Step 5: Correct the stale comment in the Deployment**

`argocd/apps/jobboard/base/app-deployment.yaml` has a comment saying the `:latest` tag "already has a rollout-restart workaround for (see README.md)". That workaround is gone. Rewrite it: the digest is now pinned by image-updater's write-back, and `imagePullPolicy: Always` stays explicit for the reason the comment already gives.

- [ ] **Step 6: Commit**

```bash
git add argocd/apps/jobboard/base/app-deployment.yaml
git commit -m "docs(jobboard): drop the rollout-restart note"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` (the "## jobboard image tag" section and "What actually runs")
- Modify: `argocd/README.md` (directory structure)
- Modify: `docs/rebuild.md` (the relocated merge-order caveat)

- [ ] **Step 1: README.md**

Replace the "## jobboard image tag" section wholesale. It currently documents `kubectl rollout restart deployment/jobboard -n jobboard` as the workaround for a moving `:latest` tag. Describe instead: image-updater watches the digest behind `latest`, commits a digest pin to `.argocd-source-jobboard.yaml` on the dev overlay, and ArgoCD syncs that commit. Note that commits from the PAT identity appearing in `git log` are expected, not a compromise.

Add `argocd-image-updater` to "What actually runs".

- [ ] **Step 2: argocd/README.md**

Add `apps/image-updater/` to the directory structure, marked as a Helm values directory where `kustomize build` fails by design — the same note `harbor` and `ingress-nginx` carry.

- [ ] **Step 3: docs/rebuild.md**

The merge-order caveat relocated by `2026-09-10-vault-avp.md` Task 7 — that the app repo's `image` CI job must publish `:latest` before this repo is pushed — still applies at bootstrap, because image-updater cannot resolve a digest for an image that does not exist yet. Add one sentence saying so where the caveat now lives.

- [ ] **Step 4: Commit and push**

```bash
git add README.md argocd/README.md docs/rebuild.md
git commit -m "docs(jobboard): record automatic image updates"
git push
```

---

## Done when

- `kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-image-updater` shows `Running`
- `kubectl -n argocd get secret git-creds` decodes to the real username, not a `<path:...>` literal
- A push to the app repo's `main` results, unattended, in a digest-pinned commit on this repo's `main`
- `kubectl -n jobboard get pods -o jsonpath='{.items[*].spec.containers[*].image}'` shows an `@sha256:` pin
- `README.md` no longer documents a manual `kubectl rollout restart`
