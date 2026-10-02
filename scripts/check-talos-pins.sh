#!/usr/bin/env bash
# Check that the Talos pins in scripts/pve-bootstrap.sh match the defaults of
# the prod root (terraform/environments/prod/variables.tf). The template the
# script builds must hold the image the root expects.
#
# Usage: scripts/check-talos-pins.sh [script] [variables.tf]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/pve-bootstrap.sh}"
VARS="${2:-$HERE/../terraform/environments/prod/variables.tf}"

# The value of NAME="${NAME:-value}" in the bootstrap script.
script_pin() {
  sed -n "s/^$1=\"\${$1:-\([^}\"]*\)}\"\$/\1/p" "$SCRIPT" | head -n 1
}

# The default of variable "NAME" in variables.tf: the first default line
# after the variable's opening line and before its closing brace.
tf_default() {
  awk -v name="$1" '
    $0 ~ "^variable \"" name "\" *{" { inside = 1; next }
    inside && /^}/ { exit }
    inside && /^[[:space:]]*default[[:space:]]*=/ {
      v = $0
      sub(/^[^"]*"/, "", v)
      sub(/".*$/, "", v)
      print v
      exit
    }
  ' "$VARS"
}

status=0

compare() {
  local shell_name="$1" tf_name="$2" from_script from_tf
  from_script="$(script_pin "$shell_name")"
  from_tf="$(tf_default "$tf_name")"
  if [ -z "$from_script" ]; then
    echo "cannot read $shell_name from $SCRIPT" >&2
    exit 2
  fi
  if [ -z "$from_tf" ]; then
    echo "cannot read the default of $tf_name from $VARS" >&2
    exit 2
  fi
  if [ "$from_script" != "$from_tf" ]; then
    echo "$tf_name differs: pve-bootstrap.sh has $from_script, variables.tf has $from_tf" >&2
    status=1
  fi
}

compare TALOS_VERSION talos_version
compare TALOS_SCHEMATIC talos_schematic_id

[ "$status" -eq 0 ] && echo "talos pins match"
exit "$status"
