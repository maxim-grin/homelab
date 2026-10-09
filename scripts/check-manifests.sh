#!/usr/bin/env bash
# Render everything ArgoCD would render from this repository and schema-check
# it: every kustomization (Helm charts included, as helmCharts), and the
# Application CRs and AppProject themselves, which must carry no chart.
# Runs in CI (the `manifests` job) and locally -- same command, same
# result.
#
# Needs on PATH: kustomize, helm, yq (mikefarah v4), kubeconform.
#
# <path:...> placeholders (argocd-vault-plugin) are plain strings here. They
# are resolved against Vault only at sync time, never in this check.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

for tool in kustomize helm yq kubeconform; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

# Built-in Kubernetes schemas plus the datreeio catalogue for CRDs
# (Application, AppProject, ClusterIssuer, ServiceMonitor, ...).
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Every environment's Application CRs, not only dev's: a mistake in a prod
# Application (a key at the wrong level, which -strict rejects) reaches the
# cluster as a silently ignored field.
app_files=(argocd/environments/*/applications/*.yaml)

work=$(mktemp -d)
# `kustomize build --enable-helm` pulls charts into a `charts/` directory
# beside each kustomization (gitignored). Remember the ones that exist now
# and remove only the ones this run created.
charts_before=$(find argocd -type d -name charts | sort)
cleanup() {
  rm -rf "$work"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$charts_before" | grep -qxF "$d" || rm -rf "$d"
  done < <(find argocd -type d -name charts | sort)
}
trap cleanup EXIT
failed=0

# This applies to every schema_check call (kustomize output, argocd/base and
# the Application CRs too); a CRD committed under argocd/ is therefore not
# validated.
# CustomResourceDefinition is skipped: the charts' own CRDs (cert-manager)
# are rendered, and neither the built-in schemas nor the datree
# catalogue publish one for that kind.
schema_check() {
  kubeconform -strict -summary -skip CustomResourceDefinition \
    -schema-location default -schema-location "$CRD_SCHEMAS" "$@"
}

fail() {
  echo "FAIL: $*" >&2
  failed=1
}

echo "== kustomize"
while IFS= read -r kfile; do
  dir=$(dirname "$kfile")
  echo "-- $dir"
  kustomize build --enable-helm "$dir" > "$work/out.yaml" || { fail "kustomize build $dir"; continue; }
  # A kustomization that names helmCharts and renders nothing has lost its
  # chart silently; the schema check below passes on an empty file.
  if grep -q '^helmCharts:' "$kfile"; then
    docs=$(grep -c '^kind:' "$work/out.yaml" || true)
    [ "$docs" -gt 0 ] || { fail "kustomize build $dir rendered no documents"; continue; }
  fi
  schema_check "$work/out.yaml" || fail "kubeconform $dir"
done < <(find argocd -name kustomization.yaml | sort)

echo "== no Helm sources in Application CRs"
# ADR 0026: charts are rendered by kustomize helmCharts (built above), never
# by an Application or the ApplicationSet template with a `chart:` source.
# Any map carrying a `chart` key under an Application CR fails here.
for app in "${app_files[@]}"; do
  count=$(yq '[.. | select(tag == "!!map") | select(has("chart"))] | length' "$app" | awk '{ n += $1 } END { print n + 0 }')
  [ "$count" -eq 0 ] || fail "$app has a chart: source; use kustomize helmCharts"
done

echo "== argocd resources"
# Not the kustomization.yaml files: those are not Kubernetes objects.
mapfile -t plain < <(find argocd/base argocd/environments -name '*.yaml' ! -name kustomization.yaml | sort)
schema_check "${plain[@]}" || fail "kubeconform argocd resources"

echo "== applicationset"
scripts/check-appsets.sh . || fail "check-appsets"

if [ "$failed" -ne 0 ]; then
  echo "check-manifests: FAILED" >&2
  exit 1
fi
echo "check-manifests: ok"
