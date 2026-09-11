# ArgoCD Self-Management and Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `homelab` AppProject sync itself from git, and reach the ArgoCD UI at `argocd.mgryn.cc` instead of a NodePort.

**Architecture:** A new Application under `argocd/environments/dev/applications/` points at `argocd/base/`, so `root-dev` picks it up and ArgoCD syncs the AppProject like any other manifest. The ingress is configured through `argocd_helm_values` in the Ansible `argocd` role, since ArgoCD itself is installed by Ansible and cannot deploy its own ingress before it exists.

**Tech Stack:** ArgoCD app-of-apps, `kubernetes.core` Ansible collection, ingress-nginx (DaemonSet on host ports 80/443), Helm chart `argo-cd` v8.6.3.

**Spec:** `docs/superpowers/specs/2026-09-10-vault-avp-design.md` (Layers 4 and 5, and their entries in Documentation changes)

**Order:** This plan is independent of Vault and lands FIRST. Plan
`2026-09-10-vault-avp.md` extends the same `argocd_helm_values` variable this
plan introduces, so landing that one first causes a conflict.

## Global Constraints

- **ArgoCD syncs `main` from GitHub, not the working copy.** A commit is not a deploy. Nothing in `argocd/` takes effect until pushed.
- Branch before the first commit: `git checkout -b <change-name>`. `main` receives finished work as a merge.
- Conventional Commits. Subject <= 50 chars, imperative, lowercase, no trailing period. Body wrapped at 72. Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `ops`.
- **No `Co-Authored-By` trailer and no generated-with footer.** This overrides any default attribution instruction.
- No test suite exists. Verification is the tool checks plus inspecting the cluster. "Synced" is not "works".
- `ansible-lint` runs at the **production** profile.
- `argocd/apps/harbor/dev` and `argocd/apps/ingress-nginx/dev` hold only `values.yaml`; `kustomize build` on them fails by design.
- Hostnames resolve via `/etc/hosts` on the workstation. There is no DNS server and no LoadBalancer.
- Steps marked **[operator]** need cluster or Proxmox access that an agent in this repo does not have. Stop and hand them to the human.

---

### Task 1: AppProject syncs itself

**Files:**
- Create: `argocd/environments/dev/applications/argocd-config.yaml`
- Modify: `argocd/README.md` (the "Step 1: Apply ArgoCD Projects (One-time Setup)" section)
- Modify: `CLAUDE.md` (the "How a change reaches the cluster" table)
- Modify: `docs/rebuild.md` (rebuild-order step 9)

**Interfaces:**
- Consumes: the existing `root-dev` Application at `argocd/environments/dev/applications/app-of-apps.yaml`, which syncs `path: argocd/environments/dev/applications/` with `directory.recurse: false` and `exclude: "app-of-apps.yaml"`. Any new file in that directory is picked up automatically.
- Produces: an Application named `argocd-config` that owns `argocd/base/`. Plan `2026-09-10-image-updater.md` relies on this to add `https://argoproj.github.io/argo-helm` to `sourceRepos` by pushing rather than by `kubectl apply`.

- [ ] **Step 1: Confirm the current manual-apply behaviour**

Establish the "before" state so the change is provable.

```bash
kubectl -n argocd get appproject homelab -o jsonpath='{.metadata.labels}' ; echo
```

Expected: no `app.kubernetes.io/instance` label — nothing owns it. **[operator]**

- [ ] **Step 2: Write the Application**

Create `argocd/environments/dev/applications/argocd-config.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-config
  namespace: argocd
  # No resources-finalizer here, deliberately. Every other Application in
  # this directory carries one so deleting the Application removes its
  # workloads. Doing that here would delete the AppProject that authorises
  # every application in the cluster.
spec:
  project: homelab
  source:
    repoURL: https://github.com/maxim-grin/homelab.git
    targetRevision: main
    path: argocd/base
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      # prune stays false: this Application manages the AppProject that
      # authorises every other Application. A prune that removed it would
      # orphan the whole cluster at once.
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

- [ ] **Step 3: Validate it parses before pushing**

```bash
kubectl apply --dry-run=client -f argocd/environments/dev/applications/argocd-config.yaml
```

Expected: `application.argoproj.io/argocd-config created (dry run)`. **[operator]**

If no cluster is reachable, fall back to a schema-free parse check:

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('argocd/environments/dev/applications/argocd-config.yaml')); print('parsed')"
```

- [ ] **Step 4: Commit and push**

```bash
git add argocd/environments/dev/applications/argocd-config.yaml
git commit -m "feat(argocd): let the appproject sync itself"
git push
```

- [ ] **Step 5: Watch it take effect**

ArgoCD polls roughly every 3 minutes.

```bash
kubectl -n argocd get application argocd-config
kubectl -n argocd get appproject homelab -o jsonpath='{.metadata.labels}' ; echo
```

Expected: the Application reports `Synced`/`Healthy`, and the AppProject now carries `app.kubernetes.io/instance: argocd-config` — the label that proves ArgoCD owns it. **[operator]**

- [ ] **Step 6: Prove the manual apply is gone**

This is the actual acceptance test. Add a harmless entry to the allowlist, push, and confirm it arrives with no `kubectl apply`.

```bash
# add "https://argoproj.github.io/argo-helm" to sourceRepos in argocd/base/projects.yaml
git add argocd/base/projects.yaml
git commit -m "chore(argocd): allow the argo helm repository"
git push
# wait for the poll, then:
kubectl -n argocd get appproject homelab -o jsonpath='{.spec.sourceRepos}' ; echo
```

Expected: the new repo appears without anyone running `kubectl apply`. This entry is also a prerequisite for the image-updater plan. **[operator]**

- [ ] **Step 7: Update the three documents that now describe the old behaviour**

`argocd/README.md` — the "Step 1: Apply ArgoCD Projects (One-time Setup)" heading is currently misleading, because the apply recurs on every `sourceRepos` change. Rewrite it to say the apply is genuinely one-time at bootstrap, and that `argocd-config` syncs it thereafter. Explain why `prune: false`.

`CLAUDE.md` — in the "How a change reaches the cluster" table, the `argocd/base/projects.yaml` row currently reads `kubectl apply -f` **by hand** / immediately. Change it to `git push`, then ArgoCD syncs / on Argo's next poll, ~3 min. Then rewrite the paragraph beneath the table: the exception it describes is now bootstrap-only, and the "A new Helm chart repository must be added to its `sourceRepos` allowlist and applied by hand" sentence must lose the "and applied by hand".

`docs/rebuild.md` — rebuild-order step 9 keeps its `kubectl apply`, because `root-dev` is itself `project: homelab` and cannot sync until the project authorising it exists. Add one sentence saying it is needed only at bootstrap and that `argocd-config` owns it afterwards.

- [ ] **Step 8: Commit the documentation**

```bash
git add argocd/README.md CLAUDE.md docs/rebuild.md
git commit -m "docs(argocd): appproject is self-managing now"
git push
```

---

### Task 2: ArgoCD UI at argocd.mgryn.cc

**Files:**
- Modify: `ansible/roles/argocd/defaults/main.yaml` (the `argocd_helm_values` variable, currently `{}`)
- Modify: `README.md` ("What actually runs" and "Day-to-day")
- Modify: `docs/rebuild.md` (rebuild-order step 13, the `/etc/hosts` step)

**Interfaces:**
- Consumes: `ingress-nginx`, already running as a DaemonSet on host ports 80/443 with `ingressClassName: nginx`, matching `argocd/apps/jobboard/dev/ingress.yaml`.
- Produces: `argocd_helm_values` as a populated dict with a `server` key. Plan `2026-09-10-vault-avp.md` Task 5 adds a sibling `repoServer` key to this same variable. Do not restructure it there — add alongside.

- [ ] **Step 1: Record how the UI is reached today**

```bash
kubectl -n argocd get svc argocd-server
```

Expected: `NodePort`, ports 32080/32443. `ansible/playbooks/argocd-dev.yaml` sets `argocd_nodeport_enabled: true` in its `vars`, overriding the role default of `false`. **[operator]**

- [ ] **Step 2: Populate argocd_helm_values**

In `ansible/roles/argocd/defaults/main.yaml`, replace `argocd_helm_values: {}` with the block below. Keep the existing comment above it — it records why the repo-server wedged and is rewritten by the Vault plan, not this one.

```yaml
argocd_helm_values:
  configs:
    params:
      # Run argocd-server without TLS so nginx can speak plain HTTP to it.
      # This is a configs.params entry, not a server.* value -- the chart has
      # no server.insecure key and would accept one silently, leaving the
      # ingress template pointed at the HTTPS service port and every request
      # answering 502.
      server.insecure: true
  server:
    ingress:
      enabled: true
      ingressClassName: nginx
      hostname: argocd.mgryn.cc
```

No TLS block: this homelab runs plain HTTP throughout, matching `harbor.mgryn.cc` and `jobs.mgryn.cc`.

- [ ] **Step 3: Leave the NodePort alone, and say why**

`argocd-dev.yaml` keeps `argocd_nodeport_enabled: true`. The ingress depends on ingress-nginx being healthy; if it is not, the NodePort is the only way into the UI to find out why. Removing it would make an ingress-nginx failure unrecoverable without `kubectl port-forward`.

Add a comment recording that, directly above `argocd_nodeport_enabled` in `ansible/roles/argocd/defaults/main.yaml`:

```yaml
# Kept alongside the ingress on purpose. The ingress runs through
# ingress-nginx; when that is broken the NodePort is the only remaining way
# into the UI to diagnose it. argocd-dev.yaml sets this true.
argocd_nodeport_enabled: false
```

- [ ] **Step 4: Lint and syntax-check**

```bash
cd ansible
ansible-lint roles/argocd
ansible-playbook playbooks/argocd-dev.yaml --syntax-check -e @secret.yaml --ask-vault-pass
```

Expected: both clean. `ansible-lint` runs at the production profile; fix anything it raises in the file you touched.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/argocd/defaults/main.yaml
git commit -m "feat(argocd): serve the ui at argocd.mgryn.cc"
```

- [ ] **Step 6: Apply it**

This is Ansible, not ArgoCD — it takes effect on the playbook run, not on push.

```bash
cd ansible
ansible-playbook playbooks/argocd-dev.yaml -e @secret.yaml --ask-vault-pass
```

**[operator]**

- [ ] **Step 7: Verify the ingress actually serves**

```bash
kubectl -n argocd get ingress
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: argocd.mgryn.cc' http://<any node IP>/
```

Expected: an Ingress for `argocd.mgryn.cc`, the server pod `Running`, and a `200` or `307` from curl — **not** a `404` (nginx has no rule) and not a `502` (`configs.params["server.insecure"]` not applied). Harbor once reported `Healthy` for twelve hours while completely unreachable; the curl is the check that matters. **[operator]**

- [ ] **Step 8: Add the /etc/hosts entry**

On the workstation, not on a cluster node:

```bash
echo "<any node IP>  argocd.mgryn.cc" | sudo tee -a /etc/hosts
```

Then open `http://argocd.mgryn.cc` in a browser and log in. **[operator]**

- [ ] **Step 9: Update the documentation**

`README.md` — add ArgoCD's hostname to "What actually runs", and add `argocd.mgryn.cc` to "Day-to-day" beside the existing URLs.

`docs/rebuild.md` — rebuild-order step 13 lists `/etc/hosts` entries for `harbor.mgryn.cc`, `jobs.mgryn.cc` "and friends". Name `argocd.mgryn.cc` explicitly.

- [ ] **Step 10: Commit and push**

```bash
git add README.md docs/rebuild.md
git commit -m "docs(argocd): record the argocd.mgryn.cc ingress"
git push
```

---

## Done when

- `kubectl -n argocd get appproject homelab -o jsonpath='{.metadata.labels}'` shows `app.kubernetes.io/instance: argocd-config`
- A pushed change to `argocd/base/projects.yaml` reaches the cluster with no `kubectl apply`
- `curl -H 'Host: argocd.mgryn.cc' http://<node IP>/` returns 200/307
- `https://argoproj.github.io/argo-helm` is in `sourceRepos`, ready for the image-updater plan
- `CLAUDE.md`, `argocd/README.md`, `README.md` and `docs/rebuild.md` no longer describe the manual apply as recurring
