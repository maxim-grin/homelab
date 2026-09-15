# jobboard Version Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Name a published, immutable jobboard version in the dev overlay instead of tracking the mutable `:latest` tag.

**Architecture:** `argocd/apps/jobboard/base/app-deployment.yaml` names the image with no tag at all; `argocd/apps/jobboard/dev/kustomization.yaml` supplies the version through a kustomize `images:` transformer. Bumping a deploy is one line in the overlay, and `git log` on that file becomes the deploy history for dev.

**Tech Stack:** kustomize, ArgoCD (with the argocd-vault-plugin CMP on this Application), GHCR.

**Spec:** `docs/superpowers/specs/2026-09-15-jobboard-version-pinning-design.md`

**Order:** BLOCKED on the job-board repository's
`docs/superpowers/plans/2026-09-15-release-tagging.md` Task 3. That task
publishes `ghcr.io/maxim-grin/jobboard:0.1.0`. Naming a version that does not
exist yet puts the pod in `ImagePullBackOff` until it does. Confirm the tag
exists before starting Task 1.

## Global Constraints

- **ArgoCD syncs `main` from GitHub, not your working copy.** A commit is not a deploy; a push is.
- Branch before the first commit. `main` receives finished work as a merge.
- Conventional Commits. **Subject <= 50 characters**, imperative, lowercase, no trailing period. Body wrapped at 72. Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `ops`.
- **No `Co-Authored-By` trailer and no generated-with footer.**
- **No test suite.** Verification is `kustomize build` plus inspecting the cluster. "It applied" is not "it works".
- jobboard's Application sets `spec.source.plugin.name: argocd-vault-plugin`, so ArgoCD delegates generation to the CMP sidecar, whose `generate` runs `kustomize build .`. The `images:` transformer runs inside that build, so it takes effect on the plugin path exactly as on the plain one.
- `newTag` values are **quoted**. `newTag: 1.0` parses as a float and renders as `jobboard:1`.
- The version appears in **exactly one place** in this repository. Do not add it to the base, to a label, or to an annotation.
- Steps marked **[operator]** need cluster access or push rights.

---

### Task 1: Pin the version

**Files:**
- Modify: `argocd/apps/jobboard/base/app-deployment.yaml` (the `image:` line at 29 and the `imagePullPolicy` block at 30-35)
- Modify: `argocd/apps/jobboard/dev/kustomization.yaml`

**Interfaces:**
- Consumes: `ghcr.io/maxim-grin/jobboard:0.1.0`, published by the job-board repository's release plan.
- Produces: a rendered Deployment naming `ghcr.io/maxim-grin/jobboard:0.1.0`. Task 3 verifies it in the cluster.

- [ ] **Step 1: Remove the tag from the base image reference**

In `argocd/apps/jobboard/base/app-deployment.yaml`, replace:

```yaml
          image: ghcr.io/maxim-grin/jobboard:latest
```

with:

```yaml
          # No tag here on purpose. The base says WHICH image; the overlay's
          # `images:` transformer says WHICH VERSION. Naming :latest here
          # would point at a tag the app repo no longer publishes, and naming
          # a real version would be a second copy that drifts from the
          # overlay's. This way the repository holds exactly one version
          # string.
          image: ghcr.io/maxim-grin/jobboard
```

- [ ] **Step 2: Rewrite the imagePullPolicy and its comment**

Immediately below, replace the whole existing block:

```yaml
          # Explicit, not relied-on-default: the default tracks the tag
          # (Always for `:latest`, IfNotPresent otherwise). If this image
          # is ever pinned to a SHA, the default would silently flip to
          # IfNotPresent and reintroduce the stale-image confusion the
          # :latest tag already has a rollout-restart workaround for (see
          # README.md).
          imagePullPolicy: Always
```

with:

```yaml
          # Explicit, not relied-on-default: the default tracks the tag
          # (Always for `:latest`, IfNotPresent otherwise). The old comment
          # here warned that pinning would flip this to IfNotPresent and
          # reintroduce stale-image confusion. That reasoning inverts once
          # the tag is immutable: staleness comes FROM a mutable tag, and a
          # published version tag is never re-pointed, so IfNotPresent can
          # only ever resolve to the same image. It also stops the kubelet
          # re-pulling on every pod start.
          imagePullPolicy: IfNotPresent
```

- [ ] **Step 3: Add the version to the dev overlay**

Append to `argocd/apps/jobboard/dev/kustomization.yaml`:

```yaml

# The deploy history for dev: one line per release, bumped by hand after the
# app repo cuts a `v<version>` tag. Quoted deliberately -- `newTag: 1.0`
# parses as a float and renders as `jobboard:1`.
images:
  - name: ghcr.io/maxim-grin/jobboard
    newTag: "0.1.0"
```

- [ ] **Step 4: Verify the overlay renders the pinned version**

```bash
cd /home/ubuntu/homelab
kustomize build argocd/apps/jobboard/dev | grep -n "image:\|imagePullPolicy:"
```

Expected exactly:

```
        image: ghcr.io/maxim-grin/jobboard:0.1.0
        imagePullPolicy: IfNotPresent
        image: postgres:17
```

`postgres:17` must be untouched — the transformer matches by image name, and
rewriting it would mean the `name:` field is wrong.

- [ ] **Step 5: Verify the version appears exactly once**

```bash
grep -rn "0\.1\.0" argocd/apps/jobboard/ ; echo "matches: $(grep -rc '0\.1\.0' argocd/apps/jobboard/ | grep -v ':0' | wc -l)"
```

Expected: one file, one line — `dev/kustomization.yaml`. Any second hit is the
duplication this design exists to avoid.

- [ ] **Step 6: Commit**

```bash
git add argocd/apps/jobboard/base/app-deployment.yaml \
        argocd/apps/jobboard/dev/kustomization.yaml
git commit -m "feat(jobboard): pin the image to a version"
```

---

### Task 2: Correct the documentation

**Files:**
- Modify: `README.md` (the whole `## jobboard image tag` section, around lines 31-44)
- Modify: `docs/rebuild.md` (the merge-order caveat inside the app-of-apps step, around lines 433-439)

**Interfaces:**
- Consumes: the behaviour from Task 1.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Replace the README section**

In `README.md`, replace the entire `## jobboard image tag` section — heading,
prose, the fenced `kubectl rollout restart` block, and the closing sentence —
with:

```markdown
## jobboard image version

`argocd/apps/jobboard/dev/kustomization.yaml` names the published version to
run; `argocd/apps/jobboard/base/app-deployment.yaml` carries no tag. Deploying
a new build is one line:

```
newTag: "0.2.0"
```

commit, and push. The pod spec genuinely changes, so ArgoCD rolls it on the
next poll — no `kubectl rollout restart`. Rolling back is the same edit with
the previous number, and it works, which it could not when the tag was
`:latest` and a revert changed nothing.

The app repository publishes `ghcr.io/maxim-grin/jobboard:<version>` only when
a `v<version>` git tag is pushed there. Naming a version here that has not been
published yet gives `ImagePullBackOff` until it is — loud and self-correcting.
```

Note the nested fence: the inner block is three backticks inside a section that
is itself being pasted from this plan. Check the rendered file has one fenced
block, not a broken nest.

- [ ] **Step 2: Rewrite the rebuild merge-order caveat**

In `docs/rebuild.md`, replace:

```
    ArgoCD syncs the jobboard manifests as soon as this applies, but the app
    repo's `image` job only publishes `ghcr.io/maxim-grin/jobboard:latest`
    on a push to that repo's `main`, so merge order matters: merge the app
    repo to `main` first, wait for its `image` CI job to go green, *then*
    merge and push this repo. Pushing this repo before the image exists
    just trades one CrashLoop for another — AVP renders the Secrets, but
    there is no image to pull.
```

with:

```
    ArgoCD syncs the jobboard manifests as soon as this applies, and
    `argocd/apps/jobboard/dev/kustomization.yaml` names a specific published
    version. That version must already exist in GHCR: the app repo publishes
    only from a `v<version>` git tag. If it does not, the pod sits in
    `ImagePullBackOff` until someone cuts the tag, and recovers on its own
    once the image appears — the manifests are correct either way. This is
    the one ordering hazard that used to be silent: with `:latest` the pod
    would happily start the *previous* build instead.
```

- [ ] **Step 3: Verify nothing stale survives**

```bash
grep -rn "rollout restart deployment/jobboard" . --include='*.md' | grep -v docs/superpowers
grep -rn "jobboard:latest" . --include='*.md' --include='*.yaml' | grep -v docs/superpowers
```

Expected: both print nothing. Hits under `docs/superpowers/` are historical plans
and specs and are left alone.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/rebuild.md
git commit -m "docs(jobboard): describe the pinned version"
```

---

### Task 3: Deploy and verify **[operator]**

**Files:** none.

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: the pinned version running in the cluster.

**The cutover is not a no-op.** `:latest` in the cluster resolves to an earlier
build; `0.1.0` was built fresh from the app repo's `main`. Treat this as a real
deploy.

- [ ] **Step 1: Merge and push**

```bash
git checkout main && git merge --no-ff <branch> && git push origin main
```

Pushing is the deploy. ArgoCD picks it up within about three minutes.

- [ ] **Step 2: Watch the roll**

```bash
kubectl -n argocd get app jobboard -w
kubectl -n jobboard get pods -w
```

Expected: `OutOfSync` -> `Synced`, and a new pod replacing the old one. The
Deployment uses `strategy: Recreate`, so the old pod terminates before the new
one starts — a brief outage is expected here, not a fault.

- [ ] **Step 3: Confirm the running image**

```bash
kubectl -n jobboard get deploy jobboard \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected: `ghcr.io/maxim-grin/jobboard:0.1.0`. If it still reads `:latest`,
ArgoCD has not synced the new manifests — check
`kubectl -n argocd get app jobboard -o jsonpath='{.status.conditions}'` before
changing anything.

- [ ] **Step 4: Confirm it serves**

```bash
curl -sSL -o /dev/null -w '%{http_code}  %{url_effective}\n' http://jobs.mgryn.cc/
kubectl -n jobboard logs deploy/jobboard --tail=20
```

Expected: `200  http://jobs.mgryn.cc/login`, and no errors in the log. jobboard
answers `/` with a `303` to `/login`, so `-L` is required — without it curl
reports 303 and the check reads as a failure when nothing is wrong.

- [ ] **Step 5: Prove a rollback works**

Worth doing once, while you are watching, because this is the capability the
whole change buys and the first time you need it will not be a good time to
discover it does not.

Once a second version exists, bump `newTag` to it, push, confirm the new image
is running, then revert the commit and push again. The previous version should
come back on its own within a poll.
