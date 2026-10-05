#!/usr/bin/env bash
# Expand the prod ApplicationSet the way ArgoCD will and check the result:
# every generated Application name, path and destination.
#
# Usage: scripts/check-appsets.sh [root]   (root defaults to the repo root)
#
# Needs on PATH: yq (mikefarah v4).
#
# Expansion is done with yq over the cluster Secrets
# (argocd/apps/clusters/*/*.yaml) and the per-app configs
# (argocd/apps/*/config.yaml), not `argocd appset generate --core`: the CLI
# is not installed on the workstation or in CI, and the inputs are plain YAML.
# The pairs are cluster x config where the cluster's `env` label is listed in
# the config's `envs`. Strict schema validation of the set itself (a key at
# the wrong level under template.spec) is kubeconform's job in
# check-manifests.sh; the structural checks here add precise messages.
#
# Skipped, not failed, while there is nothing to expand: no ApplicationSet,
# or no cluster Secrets. A set with no config.yaml at all fails.
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

command -v yq >/dev/null || { echo "missing tool: yq" >&2; exit 2; }

set_file=argocd/environments/prod/applications/appset.yaml
project_file=argocd/base/projects.yaml
failed=0

fail() {
  echo "FAIL: $*" >&2
  failed=1
}

finish() {
  if [ "$failed" -ne 0 ]; then
    echo "check-appsets: FAILED" >&2
    exit 1
  fi
  echo "check-appsets: ok"
  exit 0
}

if [ ! -f "$set_file" ]; then
  echo "check-appsets: skipped, no $set_file"
  exit 0
fi

echo "== applicationset"

# --- misplaced keys: the set's template is {metadata, spec}; spec carries
# syncPolicy, never the template itself or a spec-level lookalike.
bad=$(yq '.spec.template | keys | .[] | select(. != "metadata" and . != "spec")' "$set_file")
for k in $bad; do
  fail "misplaced key template.$k in $set_file: it belongs under template.spec (or template.metadata)"
done
for k in syncOptions automated finalizers prune selfHeal managedNamespaceMetadata; do
  [ "$(yq ".spec.template.spec | has(\"$k\")" "$set_file")" = false ] \
    || fail "misplaced key template.spec.$k in $set_file: it belongs under template.spec.syncPolicy"
done
[ "$(yq '.spec.template.spec | has("syncPolicy")' "$set_file")" = true ] \
  || fail "misplaced key: template.spec.syncPolicy missing in $set_file (a template-level or spec-level syncPolicy does not reach the Application)"
[ "$(yq '.spec | has("template") ' "$set_file")" = true ] \
  || fail "$set_file has no spec.template"

# --- inputs
clusters=() # "name|env|server"
for f in argocd/apps/clusters/*/*.yaml; do
  [ -f "$f" ] || continue
  [ "$(yq '.metadata.labels["argocd.argoproj.io/secret-type"]' "$f")" = cluster ] || continue
  clusters+=("$(yq '.stringData.name + "|" + .metadata.labels.env + "|" + (.stringData.server // "")' "$f")")
done
configs=()
for f in argocd/apps/*/config.yaml; do
  [ -f "$f" ] && configs+=("$f")
done

if [ "${#configs[@]}" -eq 0 ]; then
  fail "$set_file references no config: no argocd/apps/*/config.yaml exists"
  finish
fi
if [ "$(yq '.spec.generators[].matrix.generators[].git.files[].path' "$set_file" | grep -cx 'argocd/apps/\*/config.yaml')" -eq 0 ]; then
  fail "$set_file does not read argocd/apps/*/config.yaml"
fi
if [ "${#clusters[@]}" -eq 0 ]; then
  echo "check-appsets: skipped expansion, no cluster Secrets under argocd/apps/clusters/"
  finish
fi

# --- render a template string for one (cluster, app) pair
render() { # TEMPLATE CLUSTER ENV DIR
  sed -E \
    -e "s/\{\{ *\.?name *\}\}/$2/g" \
    -e "s/\{\{ *\.?path\.basename *\}\}/$4/g" \
    -e "s/\{\{ *\.?metadata\.labels\.env *\}\}/$3/g" <<<"$1"
}

name_tpl=$(yq '.spec.template.metadata.name' "$set_file")
path_tpl=$(yq '.spec.template.spec.source.path' "$set_file")

# AppProject destinations: a cluster is allowed by `name` or by `server`.
dest_ok() { # CLUSTER SERVER NAMESPACE
  local n s ns
  while IFS='|' read -r n s ns; do
    # shellcheck disable=SC2053 # destination fields are glob patterns
    if { { [ -n "$n" ] && [[ "$1" == $n ]]; } || { [ -n "$s" ] && [ "$2" = "$s" ]; }; } && [[ "$3" == $ns ]]; then
      return 0
    fi
  done < <(yq '.spec.destinations[] | (.name // "") + "|" + (.server // "") + "|" + (.namespace // "*")' "$project_file")
  return 1
}

declare -A seen=()
for cfg in "${configs[@]}"; do
  dir=$(basename "$(dirname "$cfg")")
  ns=$(yq '.namespace' "$cfg")
  if ! [[ "$dir" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    fail "directory name '$dir' is not a valid DNS-1123 label (lowercase alphanumerics and '-'): the Application name is derived from it"
    continue
  fi
  [ "$(yq '.envs | tag' "$cfg")" = '!!seq' ] || { fail "$cfg: envs must be a list ([] for not deployed yet)"; continue; }
  while IFS= read -r env; do
    [ -n "$env" ] || continue
    matched=0
    for c in "${clusters[@]}"; do
      IFS='|' read -r cname cenv cserver <<<"$c"
      [ "$cenv" = "$env" ] || continue
      matched=1
      app=$(render "$name_tpl" "$cname" "$cenv" "$dir")
      path=$(render "$path_tpl" "$cname" "$cenv" "$dir")
      if [[ "$app" == *'{{'* || "$path" == *'{{'* ]]; then
        fail "$set_file: template name/path uses an expression this check cannot expand: $name_tpl, $path_tpl"
        continue
      fi
      want="$cname-$dir"
      [ "$app" = "$want" ] || fail "$set_file renders '$app' for cluster $cname, app $dir; expected '$want'"
      if ! [[ "$app" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#app}" -gt 63 ]; then
        fail "generated Application name '$app' is not a valid DNS-1123 label"
      fi
      if [ -n "${seen[$app]:-}" ]; then
        fail "duplicate Application name '$app' (from $dir and ${seen[$app]})"
      fi
      seen[$app]=$dir
      [ -d "$path" ] || fail "$app: path $path does not exist"
      dest_ok "$cname" "$cserver" "$ns" || fail "$app: destination cluster '$cname' namespace '$ns' not allowed by $project_file"
      echo "-- $app -> $path"
    done
    [ "$matched" -eq 1 ] || fail "$cfg lists env '$env' that no cluster Secret provides"
  done < <(yq '.envs[]' "$cfg")
done

finish
