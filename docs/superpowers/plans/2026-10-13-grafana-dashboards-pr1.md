# Grafana Dashboards as Code, PR 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking. Per CLAUDE.md, this plan
> records decisions, files, order and checks, not finished code: the
> implementer writes the code. Exact values stay verbatim.

**Goal:** Jsonnet dashboards render to committed JSON, ArgoCD delivers
them to prod Grafana, and the first two, Homelab overview and Proxmox,
are live.

**Architecture:** `dashboards/src/*.jsonnet` plus shared `dashboards/lib/`
render to `argocd/apps/grafana-dashboards/prod/*.json`. A kustomize
`configMapGenerator` wraps each JSON in a `grafana_dashboard`-labelled
ConfigMap in `monitoring`, which the chart's sidecar already loads. A
check script re-renders and fails on drift; CI runs it on PRs touching
dashboards.

**Tech Stack:** go-jsonnet, jsonnet-bundler, Grafonnet, kustomize,
ArgoCD ApplicationSet (ADR 0026), GitHub Actions.

**Spec:** [2026-10-13-grafana-dashboards-design.md](../specs/2026-10-13-grafana-dashboards-design.md)

This is PR 1 of two. The jobboard and platform dashboards and ArgoCD
scraping are PR 2, with their own plan. PR 1 lands on the existing draft
branch `grafana-dashboards-as-code` (#155).

## Global Constraints

- go-jsonnet `v0.22.0`; asset `go-jsonnet_0.22.0_linux_amd64.tar.gz`,
  SHA-256 `e87a93ea44e34da92c15636205c7f2240bf3ac92d00ccb855dbb4e7e03ea6941`.
- jsonnet-bundler `v0.6.0`; asset `jb-linux-amd64`, SHA-256
  `78e54afbbc3ff3e0942b1576b4992277df4f6beb64cddd58528a76f0cd70db54`
  (GitHub publishes no digest for it; computed from the download).
- Grafonnet from `github.com/grafana/grafonnet`, subdir
  `gen/grafonnet-v11.4.0`, locked to commit
  `41e6bfcbe4ef1054298ffff8664f1354c897dd2d`. Task 1 checks the chart's
  Grafana version accepts the schema; `gen/grafonnet-v13.0.0` exists as
  the alternative.
- Datasource: Prometheus, uid `prometheus` (the chart's provisioned
  default). No other datasource uid appears in a dashboard.
- Dashboard ConfigMaps: namespace `monitoring`, label
  `grafana_dashboard: "1"`, annotation `grafana_folder: Homelab`, no
  name hash suffix (a hash renames the ConfigMap on every edit and
  leaves the old one in Grafana until pruned).
- The app's `config.yaml` sets `env: prod`, `namespace: monitoring`,
  `createNamespace: false`, `serverSideApply: true`. No dev entry.
- Conventional Commits, subject at most 50 characters, no
  `Co-Authored-By`, no generated-with line (CLAUDE.md). Never
  `--no-verify`.
- No secret values or `<path:...>` placeholders: nothing here is secret.
- Do not merge. The PR stays draft until all tasks are verified, then
  `gh pr ready 155`.

## Review Focus

- Render drift: a source edited without re-rendering must fail
  `check-dashboards.sh`, and a render the script did not produce must
  fail too (hand-edited JSON).
- A dashboard that renders but whose panels show "No data": every query
  must use a metric present in live Prometheus (verified in Task 4).
- Two dashboards with the same `uid`: Grafana silently keeps one. The
  check must reject duplicate uids.
- A new `.jsonnet` in `src/` with no entry in the kustomization:
  rendered but never delivered. The check must fail on it.
- Sidecar loads a dashboard twice, or deletes one, when the ConfigMap
  is renamed: covered by `disableNameSuffixHash` and a fixed name.

## File Structure

```txt
dashboards/jsonnetfile.json, jsonnetfile.lock.json
dashboards/lib/*.libsonnet          shared helpers, one concern per file
dashboards/src/overview.jsonnet, proxmox.jsonnet
dashboards/.gitignore               vendor/
argocd/apps/grafana-dashboards/config.yaml
argocd/apps/grafana-dashboards/prod/kustomization.yaml
argocd/apps/grafana-dashboards/prod/overview.json, proxmox.json
scripts/check-dashboards.sh
scripts/tests/check-dashboards.test.sh (+ fixtures/dashboards/)
.github/workflows/ci.yaml           new `dashboards` job, filter, env pins
.pre-commit-config.yaml             jsonnetfmt hook
docs/decisions/0032-dashboards-as-jsonnet.md
README.md, docs/operations.md, docs/runbooks/*.md
```

---

### Task 1: Toolchain and check script

**Files:**

- Create: `dashboards/jsonnetfile.json`, `dashboards/jsonnetfile.lock.json`,
  `dashboards/.gitignore`, `scripts/check-dashboards.sh`,
  `scripts/tests/check-dashboards.test.sh`,
  `scripts/tests/fixtures/dashboards/`
- Modify: `.github/workflows/ci.yaml`

**Interfaces:**

- Produces: `scripts/check-dashboards.sh` with no arguments. Exit 0 when
  every `dashboards/src/<n>.jsonnet` renders to exactly
  `argocd/apps/grafana-dashboards/prod/<n>.json`, exit 1 on drift, exit 2
  on a missing tool. `scripts/check-dashboards.sh --write` renders in
  place instead of comparing. Both honour `DASHBOARDS_ROOT` (default: the
  repo root) so the test can point at fixtures.
- Consumes: `jsonnet`, `jsonnetfmt`, `jb`, `kustomize`, `yq` on PATH.

- [x] **Step 1: Install the pinned tools locally** from the constraints
      above, verifying each SHA-256, into a directory outside the repo.
      Run `jsonnet --version`; expected `v0.22.0`.
- [x] **Step 2: Write the test first.** `check-dashboards.test.sh`
      builds fixtures and asserts exit codes for: matching render (0);
      stale JSON (1); hand-edited JSON (1); `src` file with no JSON (1);
      JSON with no `src` (1); duplicate `uid` across two dashboards (1);
      `src` file missing from the kustomization (1); missing tool (2).
      Run it; expected: fails, script absent.
- [x] **Step 3: Write `check-dashboards.sh`** to make the test pass.
      Pattern after `scripts/check-manifests.sh` (strict mode, repo-root
      `cd`, tool presence loop). It runs `jb install` in `dashboards/`,
      `jsonnetfmt --test` on every `.jsonnet`/`.libsonnet`, renders with
      `-J dashboards/vendor -J dashboards/lib`, and compares. Rendered
      JSON is key-sorted and indented so diffs are stable.
- [x] **Step 4: Initialise jb.** `jb init`, then `jb install` the
      Grafonnet dependency with the subdir and commit above. Confirm the
      lock file records that commit. Check the Grafana version the chart
      ships (`argocd/apps/kube-prometheus-stack/prod/charts/` after
      `kustomize build --enable-helm`) accepts the v11.4.0 schema; if
      not, switch to v13.0.0 and record why in the ADR.
- [x] **Step 5: CI.** Add `JSONNET_VERSION`, `JSONNET_SHA256`,
      `JB_VERSION`, `JB_SHA256` to the workflow env block with
      `# renovate:` comments in the existing style. Add a `dashboards`
      output and path filter (`*ci`, `dashboards/**`,
      `argocd/apps/grafana-dashboards/**`,
      `scripts/check-dashboards.sh`) and a `dashboards` job gated like
      `manifests`, which downloads, checksums and installs the three
      tools (kustomize, yq as the `manifests` job does) and runs the
      script and its test. Add both to the `shellcheck` step's file list.
- [x] **Step 6: Verify.** `scripts/tests/check-dashboards.test.sh` passes;
      `shellcheck` clean; `pre-commit run --all-files` passes.
- [x] **Step 7: Commit** `feat: add dashboard render check`.

### Task 2: Library, app skeleton, delivery

**Files:**

- Create: `dashboards/lib/*.libsonnet`,
  `argocd/apps/grafana-dashboards/config.yaml`,
  `argocd/apps/grafana-dashboards/prod/kustomization.yaml`
- Modify: `.pre-commit-config.yaml`

**Interfaces:**

- Produces (lib): `dashboard(title, uid, tags)`, `stat(title, expr)`,
  `timeseries(title, exprs, unit)`, `table(title, expr)`, a fixed
  `ds` constant for the `prometheus` datasource, and one colour map for
  thresholds (green/amber/red). Names are the implementer's to finalise
  but must be used identically by both dashboards; record them in
  `dashboards/lib/README.md`.
- Produces (app): kustomization generating one ConfigMap per
  `prod/*.json` with the Global Constraints' label, annotation, namespace
  and no hash suffix, listing each dashboard explicitly.

- [x] **Step 1: Write the lib** with the helpers above. Panels share
      sizes, units and colour thresholds, so the dashboards are visually
      consistent. A `uid` is derived from the dashboard's filename, never
      random.
- [x] **Step 2: Write `config.yaml`** from the Global Constraints, with a
      header comment in the style of the other apps' (ordering: after
      `kube-prometheus-stack`; why `serverSideApply`).
- [x] **Step 3: Write the kustomization** with an empty-safe structure;
      the dashboards are added in Tasks 3 and 4.
- [x] **Step 4: Add a `jsonnetfmt` pre-commit hook** (`language: system`,
      matching how `ansible-lint` is declared, with a `files:` filter for
      `.jsonnet`/`.libsonnet`). Add its id to `SKIP` in the CI
      `pre-commit` job, since the `dashboards` job runs it.
- [x] **Step 5: Verify.** `scripts/check-appsets.sh` passes (the app
      appears as `prod-grafana-dashboards`);
      `scripts/check-manifests.sh` passes; `pre-commit run --all-files`
      passes.
- [x] **Step 6: Commit** `feat: add grafana-dashboards app`.

### Task 3: Homelab overview dashboard

**Files:**

- Create: `dashboards/src/overview.jsonnet`,
  `argocd/apps/grafana-dashboards/prod/overview.json`
- Modify: `argocd/apps/grafana-dashboards/prod/kustomization.yaml`

**Interfaces:**

- Consumes: the lib from Task 2.
- Produces: uid `homelab-overview`. Task 4 links to it.

Panels (stat row, then a firing-alerts table): nodes up (`up` for the
node-exporter job), pods not ready (kube-state-metrics
`kube_pod_status_ready{condition="false"}`), firing alerts (`ALERTS` with
`alertstate="firing"`, `Watchdog` excluded), certificates expiring within
14 days (`certmanager_certificate_expiration_timestamp_seconds`),
Proxmox thin-pool use (the series `ProxmoxThinPoolNearlyFull` in
`argocd/apps/alerts/prod/rules.yaml` reads), `jobs.mgryn.cc` request rate
and 5xx ratio (`nginx_ingress_controller_requests`, `host` label). A
links row to the Proxmox dashboard (by uid) and to the chart's
kubernetes-mixin and node-exporter dashboards.

- [x] **Step 1: Read the existing alert expressions** in
      `alerts/prod/rules.yaml` and reuse their metric names and label
      matchers verbatim where they overlap.
- [x] **Step 2: Write `overview.jsonnet`**, render with
      `scripts/check-dashboards.sh --write`, add it to the kustomization.
- [x] **Step 3: Verify.** `scripts/check-dashboards.sh` exits 0;
      `kustomize build argocd/apps/grafana-dashboards/prod` yields a
      ConfigMap with the label and annotation; the render is a valid
      Grafana dashboard JSON (`jq .uid`).
- [x] **Step 4: Commit** `feat: add homelab overview dashboard`.

### Task 4: Proxmox dashboard

**Files:**

- Create: `dashboards/src/proxmox.jsonnet`,
  `argocd/apps/grafana-dashboards/prod/proxmox.json`
- Modify: `argocd/apps/grafana-dashboards/prod/kustomization.yaml`

**Interfaces:**

- Consumes: the lib; uid `homelab-overview` for the back-link.
- Produces: uid `proxmox`.

Rows: health (exporter up, host up, guests running vs stopped split VMs
and LXCs, uptime); host (CPU, memory, swap); storage (use per storage
and the thin-pool, as a table with colour-coded status); guests (per-guest
CPU, memory, disk read/write, network in/out, up/down table). A `guest`
template variable filters the guest rows.

- [x] **Step 1: Get the real metric names.** This needs the operator:
      ask the user to run, on the Mac against the prod context,
      `kubectl -n monitoring port-forward svc/pve-exporter 9221` and
      `curl -s 'localhost:9221/pve?target=<proxmox-ip>'`, and paste the
      distinct metric names and label sets. Do not write queries from the
      community dashboards (24550, 10347, 21118) without checking each
      name against that output. Record the names used in a comment at
      the top of `proxmox.jsonnet`.
- [x] **Step 2: Write `proxmox.jsonnet`**, render, add to the
      kustomization.
- [x] **Step 3: Verify.** `scripts/check-dashboards.sh` exits 0; every
      metric in the file appears in the pasted output (grep each one);
      `kustomize build` shows two ConfigMaps.
- [x] **Step 4: Commit** `feat: add proxmox dashboard`.

### Task 5: Docs and ADR

**Files:**

- Create: `docs/decisions/0032-dashboards-as-jsonnet.md`
- Modify: `README.md` (apps table and, if it lists apps, the Mermaid
  diagram), `docs/operations.md`, `docs/runbooks/README.md` plus the
  runbook that fits (`checks.md`), `docs/decisions/README.md`

- [x] **Step 1: ADR 0032**, format as 0031: context (UI dashboards die
      with the SSD, 2021 community JSON), decision (jsonnet source,
      rendered JSON committed, community dashboards as reference only,
      no full mixin format, Grafonnet version and why), consequences
      (toolchain pins, render step, Renovate comments).
- [x] **Step 2: Operations section** on editing a dashboard: edit
      `dashboards/src`, run `scripts/check-dashboards.sh --write`,
      commit both, merge, sync. Runbook entry with the same commands;
      link it from the PR's operator checklist rather than restating.
- [x] **Step 3: README** row for the new app; check the Mermaid diagram
      needs no change.
- [x] **Step 4: Verify.** `scripts/check-runbooks.sh` and
      `pre-commit run --all-files` pass.
- [x] **Step 5: Commit** `docs: document dashboards as code`.

### Task 6: Finish

- [x] **Step 1: Run everything:** `pre-commit run --all-files`,
      `scripts/check-manifests.sh`, `scripts/check-appsets.sh`,
      `scripts/check-dashboards.sh`, the new and existing script tests.
- [ ] **Step 2: Push and watch CI.** All of `pre-commit`, `commits`,
      `terraform`, `manifests`, `scripts` and the new `dashboards`
      green.
- [ ] **Step 3: `gh pr ready 155`** and stop. Do not merge.
- [ ] **Step 4: Operator checklist in the PR body.** After merge:
      wait for Argo (about 3 minutes), then
      `kubectl -n monitoring get cm -l grafana_dashboard=1`, open
      `grafana.mgryn.cc`, check every panel of both dashboards shows
      data. "Synced" is not "works" (CLAUDE.md).
