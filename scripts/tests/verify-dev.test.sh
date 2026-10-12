#!/usr/bin/env bash
# Tests for scripts/verify-dev.sh with vault, argocd, kubectl and curl faked
# on PATH. Each fake answers from STUB_* variables and records its argv in
# $S/calls.log, so no cluster is needed.
#
# Run: bash scripts/tests/verify-dev.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../verify-dev.sh"
ORIG_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SECRET="s3cret-pw-do-not-print"

OUT=""
RC=0
S=""

fail() { printf '    %s\n' "$*" >&2; exit 1; }

make_stubs() {
  local d="$1"
  cat > "$d/vault" <<'STUB'
#!/usr/bin/env bash
echo "vault $*" >> "$S/calls.log"
case "$1" in
  status) echo "Sealed          ${STUB_SEALED:-false}"; [ "${STUB_SEALED:-false}" = false ] ;;
  kv) printf '%s' "$STUB_VAULT_PW" ;;
esac
STUB
  cat > "$d/argocd" <<'STUB'
#!/usr/bin/env bash
echo "argocd $*" >> "$S/calls.log"
[ -n "${STUB_ARGOCD_FAIL:-}" ] && { echo "FATA[0000] rpc error"; exit 20; }
printf 'SERVER NAME VERSION STATUS MESSAGE PROJECT\n'
printf 'https://10.0.0.101:6443 dev 1.34 %s\n' "${STUB_DEV_STATUS:-Successful}"
printf 'https://kubernetes.default.svc in-cluster 1.34 Successful\n'
STUB
  cat > "$d/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$S/calls.log"
if [ -n "${STUB_KUBECTL_FAIL:-}" ]; then echo "Unable to connect to the server"; exit 1; fi
case " $* " in
  *" get applications "*)
    for a in dev-cert-manager dev-cert-manager-issuers dev-ingress-nginx dev-jobboard dev-kube-prometheus-stack dev-monitoring-secrets dev-nfs-provisioner; do
      health=Healthy
      [ "$a" = "${STUB_BAD_APP:-}" ] && health=Progressing
      printf '%s Synced %s\n' "$a" "$health"
    done
    printf 'prod-alerts Synced Healthy\n' ;;
  *" get --raw "*)
    if [ "${STUB_NO_SERIES:-}" = 1 ]; then
      echo '{"status":"success","data":{"resultType":"vector","result":[]}}'
    else
      echo '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"4"]}]}}'
    fi ;;
esac
STUB
  cat > "$d/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$S/calls.log"
has_k=0; prev=""
for a in "$@"; do [ "$prev" = -K ] && [ "$a" = - ] && has_k=1; prev="$a"; done
if [ "$has_k" = 1 ]; then
  # the credential arrives on stdin; record that it did, never its value
  cat > "$S/curl.stdin"
  printf '%s' "${STUB_WRITE_CODE:-400}"
else
  printf '%s' "${STUB_JOBS_CODE:-200}"
fi
STUB
  chmod +x "$d"/vault "$d"/argocd "$d"/kubectl "$d"/curl
}

new_env() {
  local root
  root="$(mktemp -d "$TMP_ROOT/env.XXXXXX")"
  S="$root/state"
  mkdir -p "$S" "$root/bin"
  : > "$S/calls.log"
  export S
  make_stubs "$root/bin"
  export PATH="$root/bin:$ORIG_PATH"
  export PROD_KC="$root/prod.kubeconfig"
  export RW_PASSWORD="$SECRET"
  unset DEV_NODE_IP VAULT_TOKEN RW_USER
  local v
  for v in $(compgen -v STUB_); do unset "$v"; done
}

run() {
  OUT="$("$SCRIPT" "$@" 2>&1)"
  RC=$?
}

assert_rc() { [ "$RC" -eq "$1" ] || fail "expected rc $1, got $RC; output: $OUT"; }
assert_out_contains() {
  case "$OUT" in *"$1"*) ;; *) fail "output lacks '$1'; output: $OUT" ;; esac
}
assert_out_lacks() {
  case "$OUT" in *"$1"*) fail "output unexpectedly has '$1'" ;; *) ;; esac
}

# ---- cases -----------------------------------------------------------------

test_all_pass() {
  run 10.0.0.101
  assert_rc 0
  assert_out_contains "PASS  vault unsealed"
  assert_out_contains "PASS  cluster dev is Successful"
  assert_out_contains "PASS  every dev-* Application is Synced and Healthy"
  assert_out_contains "PASS  all expected dev-* Applications exist"
  assert_out_contains "PASS  dev-jobs.mgryn.cc via 10.0.0.101 answers 200"
  assert_out_contains "PASS  up{cluster=\"dev\"} has a series"
  assert_out_contains "not 413"
  assert_out_lacks "FAIL"
  assert_out_lacks "prod-alerts"
  # vault status is the first thing run
  [ "$(head -n1 "$S/calls.log")" = "vault status" ] || fail "vault status not first"
  grep -q -- 'Host: dev-jobs.mgryn.cc' "$S/calls.log" || fail "no Host header"
}

test_secret_never_printed_or_in_argv() {
  run 10.0.0.101
  assert_rc 0
  assert_out_lacks "$SECRET"
  ! grep -q "$SECRET" "$S/calls.log" || fail "credential appears in a command line"
  grep -q "$SECRET" "$S/curl.stdin" || fail "credential did not reach curl on stdin"
}

test_node_ip_from_env() {
  DEV_NODE_IP=10.0.0.201 run
  assert_rc 0
  assert_out_contains "via 10.0.0.201"
}

test_vault_sealed() {
  export STUB_SEALED=true
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  vault status exited non-zero"
}

test_cluster_not_successful() {
  export STUB_DEV_STATUS=Unknown
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  cluster dev is not Successful"
  assert_out_contains "PASS  every dev-* Application is Synced and Healthy"
}

test_app_not_healthy() {
  export STUB_BAD_APP=dev-jobboard
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  not Synced and Healthy: dev-jobboard"
  assert_out_contains "PASS  cluster dev is Successful"
}

test_expected_app_missing() {
  REQUIRED_APPS="dev-cert-manager dev-nosuchapp" run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  missing dev-* Applications: dev-nosuchapp"
}

test_jobs_down() {
  export STUB_JOBS_CODE=502
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  dev-jobs.mgryn.cc via 10.0.0.101 answers '502'"
}

test_no_node_ip() {
  run
  assert_rc 1
  assert_out_contains "FAIL  no dev node address"
}

test_no_series() {
  export STUB_NO_SERIES=1
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  up{cluster=\"dev\"} is empty"
}

test_write_413() {
  export STUB_WRITE_CODE=413
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  receiver answers 413"
}

test_write_401() {
  export STUB_WRITE_CODE=401
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  receiver answers 401"
  assert_out_contains "size passed"
}

test_write_000() {
  export STUB_WRITE_CODE=000
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  receiver answers '000'"
}

test_write_403_404_fail() {
  local c
  for c in 403 404 502; do
    export STUB_WRITE_CODE=$c
    run 10.0.0.101
    assert_rc 1
    assert_out_contains "FAIL  receiver answers '$c'"
  done
}

test_write_2xx_passes() {
  export STUB_WRITE_CODE=204
  run 10.0.0.101
  assert_rc 0
  assert_out_contains "PASS  receiver answers 204"
}

test_password_with_quote_and_backslash() {
  export RW_PASSWORD='pa"ss\w\\rd'
  run 10.0.0.101
  assert_rc 0
  # curl config line: both characters escaped, nothing else changed
  grep -Fq 'user = "dev-remote-write:pa\"ss\\w\\\\rd"' "$S/curl.stdin" || fail "password not escaped: $(sed 's/:.*/:<pw>/' "$S/curl.stdin")"
  assert_out_lacks 'pa"ss'
}

test_argocd_fails() {
  export STUB_ARGOCD_FAIL=1
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  argocd cluster list failed"
  assert_out_contains "PASS  every dev-* Application is Synced and Healthy"
}

test_kubectl_fails() {
  export STUB_KUBECTL_FAIL=1
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  could not list Applications on the hub"
  assert_out_contains "FAIL  prod Prometheus query failed"
  assert_out_contains "PASS  cluster dev is Successful"
}

test_no_credential() {
  unset RW_PASSWORD
  run 10.0.0.101
  assert_rc 1
  assert_out_contains "FAIL  no remote-write credential"
}

test_credential_from_vault() {
  unset RW_PASSWORD
  export VAULT_TOKEN=tok STUB_VAULT_PW="$SECRET"
  run 10.0.0.101
  assert_rc 0
  grep -q 'vault kv get -field=password kv-dev/monitoring/remote-write' "$S/calls.log" || fail "vault kv not read"
  assert_out_lacks "$SECRET"
}

test_no_prod_kc() {
  unset PROD_KC
  run 10.0.0.101
  assert_rc 2
  assert_out_contains "PROD_KC is not set"
}

# ---- runner ----------------------------------------------------------------

passed=0
failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  new_env
  if ( "$t" ); then
    printf 'ok   %s\n' "$t"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$t"
    failed=$((failed + 1))
  fi
done
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
