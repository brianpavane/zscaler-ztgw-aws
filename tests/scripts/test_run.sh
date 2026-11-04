#!/usr/bin/env bash
#
# test_run.sh - tests for scripts/run.sh and scripts/lib/common.sh.
#
# A stub terraform binary records its arguments and the Zscaler/AWS
# environment it was started with, so the wrapper's behaviour (auth-mode
# switching, credential hygiene, var-file/workspace handling, destroy-time
# activation) is verified without a tenant.
#
#   tests/scripts/test_run.sh
#
# Compatible with macOS bash 3.2.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# --- sandbox: a copy of the repo's scripts + a minimal stack layout ---------
mkdir -p "$WORK/repo/scripts/lib" "$WORK/repo/scripts/ztgw" "$WORK/repo/config" \
         "$WORK/repo/stacks/s1/env" "$WORK/repo/stacks/gw/env" \
         "$WORK/repo/stacks/zia-activate" "$WORK/repo/stacks/bf/env" "$WORK/bin"
cp "$REPO_ROOT/scripts/run.sh" "$WORK/repo/scripts/run.sh"
cp "$REPO_ROOT/scripts/lib/common.sh" "$WORK/repo/scripts/lib/common.sh"
printf 'provider "zia" {}\n' > "$WORK/repo/stacks/s1/providers.tf"
printf 'provider "zia" {}\n' > "$WORK/repo/stacks/zia-activate/providers.tf"
printf 'name_prefix = "t"\n' > "$WORK/repo/stacks/s1/env/t1.tfvars"
printf 'provider "ztc" {}\n' > "$WORK/repo/stacks/gw/providers.tf"
printf 'region = "us-west-2"\n' > "$WORK/repo/stacks/gw/env/t1.tfvars"
printf 'provider "ztc" {}\nprovider "aws" {}\nvariable "release_routes" {}\n' > "$WORK/repo/stacks/bf/providers.tf"
printf 'vpc_id = "vpc-1"\n' > "$WORK/repo/stacks/bf/env/t1.tfvars"
: > "$WORK/repo/scripts/ztgw/ztgw.py"

# Stub python: records the client invocation instead of calling the API.
cat > "$WORK/bin/python-stub" <<'PYSTUB'
#!/usr/bin/env bash
printf 'PYTHON: %s\n' "$*" >> "$STUB_LOG"
PYSTUB
chmod +x "$WORK/bin/python-stub"

LOG="$WORK/tf.log"
cat > "$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then echo "Terraform v${STUB_TF_VERSION:-1.9.8}"; exit 0; fi
for a in "$@"; do
  if [ "$a" = "list" ] && [ -n "${STUB_STATE_LIST:-}" ]; then printf '%s\n' "$STUB_STATE_LIST"; fi
  if [ "$a" = "apply" ] && [ -n "${STUB_FAIL_APPLY:-}" ]; then printf 'ARGS: (failed) %s\n' "$*" >> "$STUB_LOG"; exit 1; fi
done
{
  printf 'ARGS:'; printf ' %s' "$@"; printf '\n'
  for v in ZSCALER_USE_LEGACY_CLIENT ZSCALER_CLIENT_ID ZSCALER_CLIENT_SECRET ZSCALER_VANITY_DOMAIN \
           ZSCALER_CLOUD ZIA_USERNAME ZIA_PASSWORD ZIA_API_KEY ZIA_CLOUD AWS_PROFILE; do
    if [ -n "${!v+x}" ]; then printf 'ENV %s=%s\n' "$v" "${!v}"; fi
  done
} >> "$STUB_LOG"
exit 0
STUB
chmod +x "$WORK/bin/terraform"

ONEAPI_ENV='ZSCALER_AUTH_MODE=oneapi
ZSCALER_CLIENT_ID=cid
ZSCALER_CLIENT_SECRET="s3cr3t value"
ZSCALER_VANITY_DOMAIN=acme
ZSCALER_CLOUD=
ZIA_USERNAME=stale-legacy-user
ZIA_PASSWORD=stale
ZIA_API_KEY=stale
ZIA_CLOUD=zscalertwo   # inline comment
AWS_PROFILE='

LEGACY_ENV='ZSCALER_AUTH_MODE=legacy
ZSCALER_CLIENT_ID=stale-oneapi-id
ZIA_USERNAME=admin@acme.com
ZIA_PASSWORD=pw
ZIA_API_KEY=key
ZIA_CLOUD=zscalerthree'

write_env() { # name content [mode]
    printf '%s\n' "$2" > "$WORK/repo/config/$1.env"
    chmod "${3:-600}" "$WORK/repo/config/$1.env"
}

run_wrapper() {
    : > "$LOG"
    OUT="$(cd "$WORK" && PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" \
           env -u ZSCALER_CLIENT_ID -u ZIA_USERNAME -u AUTO_APPROVE \
           "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
           bash "$WORK/repo/scripts/run.sh" "$@" 2>&1)"
    RC=$?
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/       | /'; }

expect_rc()        { if [ "$RC" -eq "$1" ]; then ok "$2"; else fail "$2 (rc=$RC, want $1)"; fi; }
expect_out()       { if printf '%s' "$OUT" | grep -q -- "$1"; then ok "$2"; else fail "$2 (output lacks '$1')"; fi; }
expect_log()       { if grep -q -- "$1" "$LOG"; then ok "$2"; else fail "$2 (log lacks '$1')"; cat "$LOG"; fi; }
expect_not_log()   { if grep -q -- "$1" "$LOG"; then fail "$2 (log has '$1')"; cat "$LOG"; else ok "$2"; fi; }

EXTRA_ENV=()

echo "run.sh tests"

# 1. usage
run_wrapper
expect_rc 1 "no arguments prints usage and fails"
expect_out "scripts/run.sh <env> <stack>\[@<instance>\] <action>" "usage text shown"

# 2. OneAPI mode
write_env t1 "$ONEAPI_ENV"
run_wrapper t1 s1 plan
expect_rc 0 "oneapi plan succeeds"
expect_log "ENV ZSCALER_USE_LEGACY_CLIENT=false" "oneapi exports ZSCALER_USE_LEGACY_CLIENT=false"
expect_log "ENV ZSCALER_CLIENT_SECRET=s3cr3t value" "quoted value is unquoted, spaces kept"
expect_not_log "ENV ZIA_USERNAME" "oneapi unsets stale legacy credentials"
expect_not_log "ENV ZSCALER_CLOUD" "empty ZSCALER_CLOUD is unset (production)"
expect_not_log "ENV AWS_PROFILE" "empty AWS_PROFILE is unset"
expect_log "workspace select -or-create=true t1" "workspace named after env"
expect_log "-var-file=.*stacks/s1/env/t1.tfvars" "env tfvars passed"
expect_not_log "ARGS:.*s3cr3t" "secret never on terraform command line"

# 3. Legacy mode
write_env t1 "$LEGACY_ENV"
run_wrapper t1 s1 plan
expect_rc 0 "legacy plan succeeds"
expect_log "ENV ZSCALER_USE_LEGACY_CLIENT=true" "legacy exports ZSCALER_USE_LEGACY_CLIENT=true"
expect_log "ENV ZIA_CLOUD=zscalerthree" "legacy exports ZIA_CLOUD"
expect_not_log "ENV ZSCALER_CLIENT_ID" "legacy unsets stale OneAPI credentials"

# 4. Validation failures
write_env t1 "$LEGACY_ENV" 644
run_wrapper t1 s1 plan
expect_rc 1 "world-readable env file rejected"
expect_out "has mode 644; run: chmod 600" "actual mode reported (GNU and BSD stat)"

write_env t1 "ZSCALER_AUTH_MODE=oneapi
ZSCALER_CLIENTID=typo"
run_wrapper t1 s1 plan
expect_rc 1 "unknown key rejected"
expect_out "unknown key 'ZSCALER_CLIENTID'" "unknown key named"

write_env t1 "ZSCALER_AUTH_MODE=oneapi
ZSCALER_CLIENT_ID=cid"
run_wrapper t1 s1 plan
expect_rc 1 "oneapi without secret/vanity rejected"
expect_out "ZSCALER_VANITY_DOMAIN" "missing setting named"

write_env t1 "ZSCALER_AUTH_MODE=legacy
ZIA_USERNAME=u
ZIA_PASSWORD=p
ZIA_API_KEY=k
ZIA_CLOUD=zscalerfive"
run_wrapper t1 s1 plan
expect_rc 1 "unknown legacy cloud rejected"

write_env t1 "ZSCALER_AUTH_MODE=saml"
run_wrapper t1 s1 plan
expect_rc 1 "unknown auth mode rejected"

# Single quotes are deliberate: the literal text must reach the env file.
# shellcheck disable=SC2016
write_env t1 'ZSCALER_AUTH_MODE=$(touch /tmp/pwned)'
run_wrapper t1 s1 plan
expect_rc 1 "env file is parsed, not executed"
expect_out "must be 'oneapi' or 'legacy'" "command substitution treated as literal"

write_env t1 "$ONEAPI_ENV"
run_wrapper "../t1" s1 plan
expect_rc 1 "path traversal in env name rejected"
run_wrapper t1 "../s1" plan
expect_rc 1 "path traversal in stack name rejected"
run_wrapper t1 nope plan
expect_rc 1 "unknown stack rejected"
run_wrapper t2 s1 plan
expect_rc 1 "missing env file rejected"
run_wrapper t1 s1 frobnicate
expect_rc 1 "unknown action rejected"

write_env t3 "$ONEAPI_ENV"
run_wrapper t3 s1 plan
expect_rc 1 "missing tfvars rejected"
expect_out "missing .*t3.tfvars" "missing tfvars named"
expect_not_log "plan" "terraform plan never runs without tfvars"

EXTRA_ENV=(STUB_TF_VERSION=1.6.0)
run_wrapper t1 s1 plan
expect_rc 1 "terraform < 1.7 rejected"
EXTRA_ENV=()

# 5. apply / destroy behaviour
EXTRA_ENV=(AUTO_APPROVE=1)
run_wrapper t1 s1 apply
expect_rc 0 "apply succeeds"
expect_log "ARGS: -chdir=.*stacks/s1 apply -input=false -var-file=.*-auto-approve" "AUTO_APPROVE adds -auto-approve"

run_wrapper t1 zia-activate apply
expect_rc 0 "activation stack apply succeeds without tfvars"
expect_log "-replace=zia_activation_status.this" "activation is forced with -replace"

run_wrapper t1 s1 destroy
expect_rc 0 "destroy succeeds"
expect_log "stacks/s1 destroy" "stack destroyed"
expect_log "stacks/zia-activate apply .*-replace=zia_activation_status.this" "destroy of a zia stack triggers activation"
EXTRA_ENV=()

run_wrapper t1 s1 auth-check
expect_rc 0 "auth-check succeeds"

run_wrapper --help
expect_rc 0 "--help succeeds"
expect_out "PYTHON_BIN" "help shows the whole header"

# 6. Product-aware credentials (zia vs ztc stacks)
write_env t1 "$LEGACY_ENV"
run_wrapper t1 gw plan
expect_rc 1 "legacy ztc stack without ZTC credentials rejected"
expect_out "ZTC_USERNAME" "missing ZTC setting named"

write_env t1 "ZSCALER_AUTH_MODE=legacy
ZTC_USERNAME=u
ZTC_PASSWORD=p
ZTC_API_KEY=k
ZTC_CLOUD=zscalertwo"
run_wrapper t1 gw plan
expect_rc 0 "legacy ztc stack needs only ZTC credentials"
expect_out "products=ztc" "products detected from stack"
run_wrapper t1 s1 plan
expect_rc 1 "legacy zia stack still needs ZIA credentials"

write_env t1 "ZSCALER_AUTH_MODE=legacy
ZTC_USERNAME=u
ZTC_PASSWORD=p
ZTC_API_KEY=k
ZTC_CLOUD=zscalerfive"
run_wrapper t1 gw plan
expect_rc 1 "unknown ZTC cloud rejected"

write_env t1 "ZSCALER_AUTH_MODE=oneapi
ZSCALER_CLIENT_ID=cid
ZSCALER_PRIVATE_KEY=pk
ZSCALER_VANITY_DOMAIN=acme"
run_wrapper t1 gw plan
expect_rc 1 "oneapi private-key only rejected for ztc stack"
expect_out "needs ZSCALER_CLIENT_SECRET" "reason explained"
run_wrapper t1 s1 plan
expect_rc 0 "oneapi private-key accepted for zia stack"

# 7. Destroy of a ztc stack activates Cloud & Branch Connector changes
write_env t1 "$ONEAPI_ENV"
EXTRA_ENV=(AUTO_APPROVE=1 PYTHON_BIN="$WORK/bin/python-stub")
run_wrapper t1 gw destroy
expect_rc 0 "ztc stack destroy succeeds"
expect_log "PYTHON: -I .*scripts/ztgw/ztgw.py activate" "ztc destroy runs client activation"
expect_not_log "zia-activate" "ztc-only stack does not run ZIA activation"
EXTRA_ENV=()

# 7b. Quoted values with a trailing comment keep no quotes
write_env t1 'ZSCALER_AUTH_MODE=oneapi
ZSCALER_CLIENT_ID="cid"   # the client
ZSCALER_CLIENT_SECRET='"'"'p#ss word'"'"'  # quoted, contains #
ZSCALER_VANITY_DOMAIN=acme # inline'
EXTRA_ENV=()
run_wrapper t1 s1 plan
expect_rc 0 "quoted values with trailing comments accepted"
expect_log "ENV ZSCALER_CLIENT_ID=cid$" "double-quoted value + comment: quotes and comment stripped"
expect_log "ENV ZSCALER_CLIENT_SECRET=p#ss word$" "single-quoted value keeps # and spaces"
expect_log "ENV ZSCALER_VANITY_DOMAIN=acme$" "unquoted value: inline comment stripped"
write_env t1 'ZSCALER_AUTH_MODE="oneapi'
run_wrapper t1 s1 plan
expect_rc 1 "unterminated quote rejected"

# 8. Every Zscaler production cloud is accepted in Legacy mode
for cloud in zscaler zscalerone zscalertwo zscalerthree zscloud; do
    write_env t1 "ZSCALER_AUTH_MODE=legacy
ZTC_USERNAME=u
ZTC_PASSWORD=p
ZTC_API_KEY=k
ZTC_CLOUD=${cloud}"
    run_wrapper t1 gw plan
    expect_rc 0 "legacy ZTC_CLOUD=${cloud} accepted"
    write_env t1 "ZSCALER_AUTH_MODE=legacy
ZIA_USERNAME=u
ZIA_PASSWORD=p
ZIA_API_KEY=k
ZIA_CLOUD=${cloud}"
    run_wrapper t1 s1 plan
    expect_rc 0 "legacy ZIA_CLOUD=${cloud} accepted"
done

# 9. Brownfield destroy restores routes, releases them, then destroys
write_env t1 "$ONEAPI_ENV"
EXTRA_ENV=(AUTO_APPROVE=1 PYTHON_BIN="$WORK/bin/python-stub" 'STUB_STATE_LIST=aws_route.default["usw2-az1"]')
run_wrapper t1 bf destroy
expect_rc 0 "brownfield destroy succeeds"
expect_log "stacks/bf apply .*-var=cutover=false" "routes restored with cutover=false first"
expect_log "stacks/bf state rm aws_route.default" "restored routes released from state"
expect_log "stacks/bf destroy .*-var=release_routes=true" "destroy runs with release_routes=true"
if grep -n 'stacks/bf' "$LOG" | awk -F: '/ apply /{a=$1} / state rm /{r=$1} / destroy /{d=$1} END{exit !(a<r && r<d)}'; then
    ok "restore, release, destroy run in that order"
else
    fail "restore, release, destroy run in that order"; cat "$LOG"
fi

EXTRA_ENV=(AUTO_APPROVE=1 PYTHON_BIN="$WORK/bin/python-stub" STUB_STATE_LIST=)
run_wrapper t1 bf destroy
expect_rc 0 "brownfield destroy with no managed routes succeeds"
expect_not_log "stacks/bf apply" "no restore apply when no routes are in state"
expect_log "stacks/bf destroy .*-var=release_routes=true" "destroy still releases routes"

EXTRA_ENV=(AUTO_APPROVE=1 PYTHON_BIN="$WORK/bin/python-stub" 'STUB_STATE_LIST=aws_route.default["usw2-az1"]' STUB_FAIL_APPLY=1)
run_wrapper t1 bf destroy
expect_rc 1 "failed route restore aborts destroy"
expect_not_log "stacks/bf destroy" "nothing destroyed after a failed restore"
expect_not_log "state rm" "routes not released after a failed restore"
EXTRA_ENV=()

run_wrapper t1 gw destroy
expect_not_log "release_routes" "non-brownfield destroy unchanged"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
