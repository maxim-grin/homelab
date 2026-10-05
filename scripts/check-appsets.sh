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
#
# Shape this check assumes:
#   - config.yaml is a top-level list, one entry per env the app deploys to
#     (`env`, `namespace`, ...); `[]` means deployed nowhere yet.
#   - the set has `goTemplate: true` and a matrix of a git-files generator
#     over argocd/apps/*/config.yaml (each entry is one parameter set) and a
#     cluster generator selecting `argocd.argoproj.io/secret-type: cluster`
#     and `env: "{{.env}}"`, so the env filtering is structural.
#   - the template may use only {{.name}} (cluster name), {{.path.basename}}
#     (the app directory) and {{.env}} in metadata.name and source.path, and
#     must render `<cluster>-<dir>` and `argocd/apps/<dir>/<env>`.
#   - spec.syncPolicy.applicationsSync is create-update.
#   - when any entry sets createNamespace, serverSideApply or
#     namespaceLabels, spec.templatePatch exists and reads that key. The
#     patch is checked by text, not rendered: its output is verified with
#     `argocd appset generate` on the operator's workstation.
# Strict schema validation of the set (a key at the wrong level) is
# kubeconform's job in check-manifests.sh; the structural checks here add
# precise messages.
#
# Skipped, not failed, only while there is nothing to expand: no config has
# any entry. A set with no config.yaml at all fails; configs with entries but
# no set fail; entries with no matching cluster Secret fail.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

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

configs=()
entries=0
for f in argocd/apps/*/config.yaml; do
  [ -f "$f" ] || continue
  configs+=("$f")
  if [ "$(yq 'tag' "$f")" = '!!seq' ]; then
    entries=$((entries + $(yq 'length' "$f")))
  fi
done

if [ ! -f "$set_file" ]; then
  if [ "$entries" -gt 0 ]; then
    fail "configs list envs but no ApplicationSet at $set_file"
    finish
  fi
  echo "check-appsets: skipped, no $set_file and no config entries"
  exit 0
fi

echo "== applicationset"

if [ "${#configs[@]}" -eq 0 ]; then
  fail "$set_file references no config: no argocd/apps/*/config.yaml exists"
  finish
fi

# --- the set itself
[ "$(yq '.spec.goTemplate' "$set_file")" = true ] \
  || fail "$set_file needs spec.goTemplate: true"
[ "$(yq '.spec.syncPolicy.applicationsSync' "$set_file")" = create-update ] \
  || fail "$set_file needs spec.syncPolicy.applicationsSync: create-update (applicationsSync is wrong or missing)"
if [ "$(yq '.spec.generators[].matrix.generators[].git.files[].path' "$set_file" | grep -cx 'argocd/apps/\*/config.yaml')" -eq 0 ]; then
  fail "$set_file does not read argocd/apps/*/config.yaml"
fi
filtered=$(yq '[.spec.generators[].matrix.generators[].clusters | select(. != null)
  | select(.selector.matchLabels["argocd.argoproj.io/secret-type"] == "cluster" and .selector.matchLabels.env == "{{.env}}")] | length' "$set_file")
[ "$filtered" -gt 0 ] \
  || fail "set does not filter clusters by env: the cluster generator needs matchLabels argocd.argoproj.io/secret-type: cluster and env: \"{{.env}}\""

# The template is {metadata, spec}; spec carries syncPolicy, never the
# template itself or a spec-level lookalike.
if [ "$(yq '.spec.template | tag' "$set_file")" != '!!map' ]; then
  fail "$set_file has no spec.template"
else
  for k in $(yq '.spec.template | keys | .[] | select(. != "metadata" and . != "spec")' "$set_file"); do
    fail "misplaced key template.$k in $set_file: it belongs under template.spec (or template.metadata)"
  done
  for k in syncOptions automated finalizers prune selfHeal managedNamespaceMetadata; do
    [ "$(yq ".spec.template.spec | has(\"$k\")" "$set_file")" = false ] \
      || fail "misplaced key template.spec.$k in $set_file: it belongs under template.spec.syncPolicy"
  done
  [ "$(yq '.spec.template.spec | has("syncPolicy")' "$set_file")" = true ] \
    || fail "misplaced key: template.spec.syncPolicy missing in $set_file (a template-level or spec-level syncPolicy does not reach the Application)"
fi

# --- optional per-entry settings reach the Application only through
# spec.templatePatch (go-template conditionals the plain template cannot
# express). A key some entry sets but the patch never reads is silently
# dropped: no CreateNamespace, no ServerSideApply, no namespace labels.
patch=$(yq '.spec.templatePatch // ""' "$set_file")
declare -A uses=() # config key -> "<needle in patch> <rendered marker>"
uses[createNamespace]='.createNamespace CreateNamespace=true'
uses[serverSideApply]='.serverSideApply ServerSideApply=true'
uses[namespaceLabels]='.namespaceLabels managedNamespaceMetadata'
set_keys=()
for k in createNamespace serverSideApply namespaceLabels; do
  for cfg in "${configs[@]}"; do
    [ "$(yq 'tag' "$cfg")" = '!!seq' ] || continue
    if [ "$(yq "[.[] | select(.$k != null and .$k != false and .$k != {})] | length" "$cfg")" -gt 0 ]; then
      set_keys+=("$k")
      break
    fi
  done
done
if [ "${#set_keys[@]}" -gt 0 ]; then
  if [ -z "$patch" ]; then
    fail "$set_file has no spec.templatePatch, but config entries set ${set_keys[*]}: without the patch those settings never reach the Applications"
  else
    for k in "${set_keys[@]}"; do
      for needle in ${uses[$k]}; do
        grep -qF -- "$needle" <<<"$patch" \
          || fail "$set_file: templatePatch does not handle $k (a config entry sets it; the patch never mentions '$needle')"
      done
    done
  fi
fi

# --- cluster Secrets
clusters=() # "name|env|server"
for f in argocd/apps/clusters/*/*.yaml; do
  [ -f "$f" ] || continue
  [ "$(yq '.metadata.labels["argocd.argoproj.io/secret-type"]' "$f")" = cluster ] || continue
  clusters+=("$(yq '.stringData.name + "|" + .metadata.labels.env + "|" + (.stringData.server // "")' "$f")")
done

# --- render a template string for one (cluster, env, dir) triple
render() { # TEMPLATE CLUSTER ENV DIR
  local s="$1" x
  for x in "name:$2" "env:$3" "path.basename:$4"; do
    s="${s//"{{.${x%%:*}}}"/${x#*:}}"
    s="${s//"{{ .${x%%:*} }}"/${x#*:}}"
  done
  printf '%s\n' "$s"
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
  if ! [[ "$dir" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    fail "directory name '$dir' is not a valid DNS-1123 label (lowercase alphanumerics and '-'): the Application name is derived from it"
    continue
  fi
  [ "$(yq 'tag' "$cfg")" = '!!seq' ] || { fail "$cfg must be a list of entries ([] for not deployed yet)"; continue; }
  n=$(yq 'length' "$cfg")
  for ((i = 0; i < n; i++)); do
    env=$(yq ".[$i].env // \"\"" "$cfg")
    ns=$(yq ".[$i].namespace // \"\"" "$cfg")
    [ -n "$env" ] || { fail "$cfg entry $i has no env"; continue; }
    [ -n "$ns" ] || { fail "$cfg entry $i has no namespace"; continue; }
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
      [ "$app" = "$cname-$dir" ] || fail "$set_file renders name '$app' for cluster $cname, app $dir; expected '$cname-$dir'"
      [ "$path" = "argocd/apps/$dir/$env" ] || fail "$set_file renders path '$path' for $app; expected 'argocd/apps/$dir/$env'"
      if ! [[ "$app" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#app}" -gt 63 ]; then
        fail "generated Application name '$app' is not a valid DNS-1123 label"
      fi
      if [ -n "${seen[$app]:-}" ]; then
        fail "duplicate Application name '$app' (from $dir and ${seen[$app]})"
      fi
      seen[$app]=$dir
      [ -d "argocd/apps/$dir/$env" ] || fail "$app: path argocd/apps/$dir/$env does not exist"
      dest_ok "$cname" "$cserver" "$ns" || fail "$app: destination cluster '$cname' namespace '$ns' not allowed by $project_file"
      echo "-- $app -> argocd/apps/$dir/$env"
    done
    [ "$matched" -eq 1 ] || fail "$cfg lists env '$env' that no cluster Secret provides"
  done
done

finish
