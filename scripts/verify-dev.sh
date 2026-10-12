#!/usr/bin/env bash
# Smoke-check the dev spoke after it is built or replaced. One PASS or FAIL
# line per check; exits non-zero if any check fails. Read-only except for one
# authenticated write of junk to prod's remote-write receiver (rejected as a
# bad body, never stored).
#
# Usage: scripts/verify-dev.sh [dev-node-ip]
#
# Inputs (environment; nothing secret is ever printed):
#   PROD_KC        required. Path of the prod (hub) kubeconfig.
#   DEV_NODE_IP    dev node address for the jobboard check, if no argument is
#                  given. Required one way or the other; no default, because
#                  nothing in the repo fixes the address except secret.yaml.
#   RW_USER        remote-write username. Default: dev-remote-write.
#   RW_PASSWORD    remote-write password (kv-dev/monitoring/remote-write,
#                  field `password`). If unset and VAULT_TOKEN is set, it is
#                  read from Vault with `vault kv get`. Neither: the 413
#                  check FAILs, it is never skipped.
#   VAULT_ADDR, VAULT_CACERT, VAULT_TOKEN   as in docs/runbooks/README.md.
#   RECEIVER_URL   default https://prometheus.mgryn.cc/api/v1/write.
#   BODY_BYTES     oversized body size. Default 1049600 (1 MiB + 1 KiB), over
#                  nginx's 1m default body limit.
#
# Needs on PATH: vault, argocd (logged in to the hub, see
# docs/runbooks/access.md), kubectl, curl.
set -u

PROD_KC="${PROD_KC:-}"
DEV_NODE_IP="${1:-${DEV_NODE_IP:-}}"
RW_USER="${RW_USER:-dev-remote-write}"
RECEIVER_URL="${RECEIVER_URL:-https://prometheus.mgryn.cc/api/v1/write}"
BODY_BYTES="${BODY_BYTES:-1049600}"
# Dev apps that must exist: argocd/apps/*/config.yaml entries with env dev.
REQUIRED_APPS="${REQUIRED_APPS:-dev-cert-manager dev-cert-manager-issuers dev-ingress-nginx dev-jobboard dev-kube-prometheus-stack dev-monitoring-secrets dev-nfs-provisioner}"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$PROD_KC" ]; then
  echo "PROD_KC is not set (path of the prod kubeconfig)" >&2
  exit 2
fi

# 1. Vault status, printed first. Exit 2 from `vault status` means sealed.
echo "== vault status"
if vault status; then
  pass "vault unsealed"
else
  fail "vault status exited non-zero (sealed or unreachable)"
fi

# 2. dev registered with the hub and connected.
echo "== argocd cluster list"
if clusters="$(argocd cluster list --grpc-web 2>&1)"; then
  echo "$clusters"
  if printf '%s\n' "$clusters" | awk '$2 == "dev" && $4 == "Successful" { found = 1 } END { exit !found }'; then
    pass "cluster dev is Successful"
  else
    fail "cluster dev is not Successful"
  fi
else
  echo "$clusters"
  fail "argocd cluster list failed (not logged in?)"
fi

# 3. every dev-* Application Synced and Healthy, and the expected set exists.
echo "== dev-* applications"
if apps="$(kubectl --kubeconfig "$PROD_KC" -n argocd get applications --no-headers \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>&1)"; then
  devapps="$(printf '%s\n' "$apps" | awk '$1 ~ /^dev-/')"
  echo "$devapps"
  bad="$(printf '%s\n' "$devapps" | awk 'NF && !($2 == "Synced" && $3 == "Healthy") { print $1 }')"
  if [ -z "$devapps" ]; then
    fail "no dev-* Applications on the hub"
  elif [ -n "$bad" ]; then
    fail "not Synced and Healthy: $(echo "$bad" | tr '\n' ' ')"
  else
    pass "every dev-* Application is Synced and Healthy"
  fi
  missing=""
  for a in $REQUIRED_APPS; do
    printf '%s\n' "$devapps" | awk -v a="$a" '$1 == a { f = 1 } END { exit !f }' || missing="$missing $a"
  done
  if [ -z "$missing" ]; then
    pass "all expected dev-* Applications exist"
  else
    fail "missing dev-* Applications:$missing"
  fi
else
  echo "$apps"
  fail "could not list Applications on the hub"
fi

# 4. jobboard answers through ingress-nginx on a dev node.
echo "== jobboard"
if [ -z "$DEV_NODE_IP" ]; then
  fail "no dev node address (argument or DEV_NODE_IP)"
else
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
    -H 'Host: dev-jobs.mgryn.cc' "https://$DEV_NODE_IP/" 2>/dev/null)" || true
  case "$code" in
    2?? | 3??) pass "dev-jobs.mgryn.cc via $DEV_NODE_IP answers $code" ;;
    *) fail "dev-jobs.mgryn.cc via $DEV_NODE_IP answers '${code:-none}'" ;;
  esac
fi

# 5. a cluster=dev series reached prod's Prometheus. Through the API server's
# service proxy: no port-forward process to clean up.
echo "== cluster=dev series in prod Prometheus"
q='/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=count(up%7Bcluster%3D%22dev%22%7D)'
if res="$(kubectl --kubeconfig "$PROD_KC" get --raw "$q" 2>&1)"; then
  if printf '%s' "$res" | grep -q '"result":\[{'; then
    pass "up{cluster=\"dev\"} has a series"
  else
    echo "$res"
    fail "up{cluster=\"dev\"} is empty"
  fi
else
  echo "$res"
  fail "prod Prometheus query failed"
fi

# 6. an authenticated write over the default 1m body is not 413 (Review
# Focus 7). The body is zeros: Prometheus rejects it as undecodable (4xx),
# which is fine; 413 is nginx refusing the size, 401 means the credential
# proved nothing.
echo "== oversized authenticated write"
pw="${RW_PASSWORD:-}"
if [ -z "$pw" ] && [ -n "${VAULT_TOKEN:-}" ]; then
  pw="$(vault kv get -field=password kv-dev/monitoring/remote-write 2>/dev/null)" || pw=""
fi
if [ -z "$pw" ]; then
  fail "no remote-write credential (RW_PASSWORD, or VAULT_TOKEN to read it)"
else
  head -c "$BODY_BYTES" /dev/zero > "$TMP/body"
  # The credential goes to curl on stdin as a config line, not argv. curl
  # config strings treat \ and " specially, so escape both.
  u="${RW_USER//\\/\\\\}"; u="${u//\"/\\\"}"
  p="${pw//\\/\\\\}"; p="${p//\"/\\\"}"
  code="$(printf 'user = "%s:%s"\n' "$u" "$p" | curl -s -o /dev/null -w '%{http_code}' \
    --max-time 30 -K - -X POST -H 'Content-Type: application/x-protobuf' \
    -H 'Content-Encoding: snappy' --data-binary "@$TMP/body" "$RECEIVER_URL" 2>/dev/null)" || true
  unset p
  case "$code" in
    413) fail "receiver answers 413 for a $BODY_BYTES-byte body (proxy-body-size too small)" ;;
    401) fail "receiver answers 401: the credential is rejected (nginx checks the size before auth, so the size passed, but the write is unproven)" ;;
    400 | 2??) pass "receiver answers $code for a $BODY_BYTES-byte body (not 413)" ;;
    *) fail "receiver answers '${code:-none}' (expected 400 for an undecodable body, or 2xx)" ;;
  esac
fi
unset pw

echo
if [ "$fails" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
