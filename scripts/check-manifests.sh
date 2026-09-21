#!/usr/bin/env bash
# Render everything ArgoCD would render from this repository and schema-check
# it: every kustomization, every Helm source in an Application CR, and the
# Application CRs and AppProject themselves. Runs in CI (the `manifests`
# job) and locally -- same command, same result.
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
apps_dir=argocd/environments/dev/applications

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# CustomResourceDefinition is skipped: --include-crds renders the charts' own
# CRDs (cert-manager) and neither the built-in schemas nor the datree
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
  kustomize build "$dir" > "$work/out.yaml" || { fail "kustomize build $dir"; continue; }
  schema_check "$work/out.yaml" || fail "kubeconform $dir"
done < <(find argocd -name kustomization.yaml | sort)

echo "== helm"
for app in "$apps_dir"/*.yaml; do
  # A source with `chart:` is a Helm source; the plain git source is not.
  count=$(yq '[.spec.sources[]? | select(.chart)] | length' "$app")
  [ "$count" -gt 0 ] || continue

  name=$(yq '.metadata.name' "$app")
  ns=$(yq '.spec.destination.namespace' "$app")
  repo=$(yq '.spec.sources[] | select(.chart) | .repoURL' "$app")
  chart=$(yq '.spec.sources[] | select(.chart) | .chart' "$app")
  version=$(yq '.spec.sources[] | select(.chart) | .targetRevision' "$app")
  release=$(yq ".spec.sources[] | select(.chart) | .helm.releaseName // \"$name\"" "$app")

  # `$values/argocd/...` is ArgoCD's reference to the git source; locally
  # the same file is simply relative to the repository root.
  values=()
  while IFS= read -r vf; do
    [ -n "$vf" ] || continue
    values+=(-f "${vf#\$values/}")
  done < <(yq '.spec.sources[] | select(.chart) | .helm.valueFiles[]?' "$app")

  echo "-- $name ($chart $version)"
  helm template "$release" "$chart" --repo "$repo" --version "$version" \
    --namespace "$ns" --include-crds "${values[@]}" > "$work/out.yaml" \
    || { fail "helm template $name"; continue; }
  schema_check "$work/out.yaml" || fail "kubeconform $name"
done

echo "== argocd resources"
# Not the kustomization.yaml files: those are not Kubernetes objects.
mapfile -t plain < <(find argocd/base "$apps_dir" -name '*.yaml' ! -name kustomization.yaml | sort)
schema_check "${plain[@]}" || fail "kubeconform argocd resources"

if [ "$failed" -ne 0 ]; then
  echo "check-manifests: FAILED" >&2
  exit 1
fi
echo "check-manifests: ok"
