#!/usr/bin/env bash
#
# test_deploy.sh - tests for scripts/deploy.sh (environment orchestration).
#
# A stub terraform records every call (with its -chdir stack directory), so
# phase order, workspaces, wiring files and var-file precedence are verified
# without a tenant. Wiring generation runs the real python3.
#
#   tests/scripts/test_deploy.sh
#
# Compatible with macOS bash 3.2.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
R="$WORK/repo"

# --- sandbox -----------------------------------------------------------------
mkdir -p "$R/scripts/lib" "$R/scripts/ztgw" "$R/config" "$WORK/bin"
cp "$REPO_ROOT/scripts/run.sh" "$REPO_ROOT/scripts/deploy.sh" "$R/scripts/"
cp "$REPO_ROOT/scripts/lib/common.sh" "$R/scripts/lib/"
: > "$R/scripts/ztgw/ztgw.py"

mkstack() { # name providers [extra .tf content]
    mkdir -p "$R/stacks/$1/env"
    local p out=""
    for p in $2; do out="${out}provider \"${p}\" {}"$'\n'; done
    printf '%s%s' "$out" "${3:-}" > "$R/stacks/$1/providers.tf"
}
mkstack 01-zia-url-policy zia
mkstack zia-activate zia
mkstack 02-ztgw ztc
mkstack 03-account-greenfield "ztc aws"
mkstack 03-account-brownfield "ztc aws" 'variable "release_routes" {}'
: > "$R/stacks/03-account-greenfield/onboarding.tf"
: > "$R/stacks/03-account-brownfield/onboarding.tf"
rmdir "$R/stacks/zia-activate/env"

for f in 01-zia-url-policy/env/t1 02-ztgw/env/t1 03-account-greenfield/env/t1-app1 \
         03-account-brownfield/env/t1-core; do
    printf '# test\n' > "$R/stacks/${f}.tfvars"
done

printf 'ZSCALER_AUTH_MODE=oneapi\nZSCALER_CLIENT_ID=cid\nZSCALER_CLIENT_SECRET=sec\nZSCALER_VANITY_DOMAIN=acme\n' \
    > "$R/config/t1.env"
chmod 600 "$R/config/t1.env"

write_deploy() { printf '%s\n' "$1" > "$R/config/t1.deploy"; }
FULL_DEPLOY='URL_POLICY=true
GATEWAY=true
WORKLOADS="03-account-greenfield@app1 03-account-brownfield@core"   # two accounts'

GATEWAY_OUTPUTS='{
  "location_name": {"value": "ztgw-t1-us-west-2-loc"},
  "endpoint_service_name": {"value": "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"},
  "region": {"value": "us-west-2"},
  "availability_zone_ids": {"value": ["usw2-az1", "usw2-az2"]},
  "account_group_id": {"value": 500}
}'

LOG="$WORK/tf.log"
cat > "$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then echo "Terraform v1.9.8"; exit 0; fi
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$STUB_LOG"
case " $* " in
  *" output -json"*) printf '%s\n' "${STUB_OUTPUT_JSON:-{\}}" ;;
  *" state list"*) [ -n "${STUB_STATE_LIST:-}" ] && printf '%s\n' "$STUB_STATE_LIST" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/terraform"
# python: real interpreter for inline scripts (wiring), recorded otherwise.
cat > "$WORK/bin/python-stub" <<'PYSTUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-c" ] && exec python3 "$@"; done
printf 'PYTHON: %s\n' "$*" >> "$STUB_LOG"
PYSTUB
chmod +x "$WORK/bin/python-stub"

EXTRA_ENV=()
STDIN_TEXT=""
run_deploy() {
    : > "$LOG"
    OUT="$(cd "$WORK" && printf '%s' "$STDIN_TEXT" | PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" \
           PYTHON_BIN="$WORK/bin/python-stub" \
           env -u AUTO_APPROVE ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
           bash "$R/scripts/deploy.sh" "$@" 2>&1)"
    RC=$?
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/       | /'; }
expect_rc()      { if [ "$RC" -eq "$1" ]; then ok "$2"; else fail "$2 (rc=$RC, want $1)"; fi; }
expect_out()     { if printf '%s' "$OUT" | grep -q -- "$1"; then ok "$2"; else fail "$2 (output lacks '$1')"; fi; }
expect_log()     { if grep -q -- "$1" "$LOG"; then ok "$2"; else fail "$2 (log lacks '$1')"; cat "$LOG"; fi; }
expect_not_log() { if grep -q -- "$1" "$LOG"; then fail "$2 (log has '$1')"; cat "$LOG"; else ok "$2"; fi; }
line_of() { grep -n -- "$1" "$LOG" | head -1 | cut -d: -f1; }
expect_order() { # description pattern...
    local desc="$1" prev=0 n p; shift
    for p in "$@"; do
        n="$(line_of "$p")"
        if [ -z "$n" ] || [ "$n" -le "$prev" ]; then fail "$desc (at '$p')"; cat "$LOG"; return; fi
        prev="$n"
    done
    ok "$desc"
}
expect_file_json() { # file python-expression description
    if python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" 2>/dev/null; then
        ok "$3"; else fail "$3 ($(cat "$1" 2>/dev/null || echo missing))"; fi
}

echo "deploy.sh tests"

# 1. usage and config validation
run_deploy --help
expect_rc 0 "--help succeeds"
expect_out "scripts/deploy.sh <env> <command>" "usage shown"
run_deploy t1 launch
expect_rc 1 "unknown command rejected"
run_deploy t1 up
expect_rc 1 "missing deploy file rejected"
expect_out "copy config/example.deploy" "missing deploy file explained"
write_deploy 'GATEWAY=yes'
run_deploy t1 plan
expect_rc 1 "non-boolean GATEWAY rejected"
write_deploy 'GATEWAY=true
REGION=us-west-2'
run_deploy t1 plan
expect_rc 1 "unknown key rejected"
write_deploy 'WORKLOADS="02-ztgw@x"'
run_deploy t1 plan
expect_rc 1 "non-Phase-3 workload rejected"
write_deploy 'WORKLOADS="03-account-greenfield@a 03-account-greenfield@a"'
run_deploy t1 plan
expect_rc 1 "duplicate workload rejected"
write_deploy 'WORKLOADS="03-account-greenfield@bad/name"'
run_deploy t1 plan
expect_rc 1 "invalid instance name rejected"
write_deploy 'URL_POLICY=false'
run_deploy t1 plan
expect_rc 1 "empty selection rejected"

# 2. up: order, wiring, workspaces, var-file precedence
write_deploy "$FULL_DEPLOY"
EXTRA_ENV=(AUTO_APPROVE=1 "STUB_OUTPUT_JSON=$GATEWAY_OUTPUTS")
run_deploy t1 up
expect_rc 0 "up succeeds"
expect_order "up runs gateway, wiring, policy, then workloads in order" \
    "stacks/02-ztgw apply" "stacks/02-ztgw output -json" "stacks/01-zia-url-policy apply" \
    "stacks/03-account-greenfield apply" "stacks/03-account-brownfield apply"
expect_file_json "$R/stacks/01-zia-url-policy/env/t1.wiring.tfvars.json" \
    'd == {"location_names": ["ztgw-t1-us-west-2-loc"]}' "Phase 1 wiring: gateway location"
expect_file_json "$R/stacks/03-account-greenfield/env/t1.wiring.tfvars.json" \
    'd["endpoint_service_name"].startswith("com.amazonaws.vpce.us-west-2.") and d["ztgw_account_group_id"] == 500 and d["availability_zone_ids"] == ["usw2-az1","usw2-az2"] and d["region"] == "us-west-2"' \
    "Phase 3 wiring: endpoint service, group, AZs, region"
expect_file_json "$R/stacks/03-account-brownfield/env/t1.wiring.tfvars.json" \
    '"endpoint_service_name" in d' "wiring written for every Phase 3 stack"
expect_log "workspace select -or-create=true t1-app1" "workload instance gets its own workspace"
expect_log "workspace select -or-create=true t1-core" "second instance gets its own workspace"
expect_log "03-account-greenfield apply .*env/t1.wiring.tfvars.json -var-file=.*env/t1-app1.tfvars" \
    "wiring loaded before the instance tfvars (tfvars win)"
expect_log "01-zia-url-policy apply .*env/t1.wiring.tfvars.json -var-file=.*env/t1.tfvars" \
    "Phase 1 gets the gateway location from wiring"
expect_log "-auto-approve" "AUTO_APPROVE passed through"

# 3. up stops before applying anything if a tfvars file is missing
mv "$R/stacks/03-account-brownfield/env/t1-core.tfvars" "$WORK/held.tfvars"
run_deploy t1 up
expect_rc 1 "up with a missing tfvars fails"
expect_out "t1-core.tfvars" "missing file named"
expect_not_log " apply" "nothing applied when preflight fails"
mv "$WORK/held.tfvars" "$R/stacks/03-account-brownfield/env/t1-core.tfvars"

# 4. up stops after the gateway if its outputs are incomplete
rm -f "$R"/stacks/*/env/t1.wiring.tfvars.json
EXTRA_ENV=(AUTO_APPROVE=1 'STUB_OUTPUT_JSON={"location_name": {"value": ""}}')
run_deploy t1 up
expect_rc 1 "up fails when gateway outputs are incomplete"
expect_out "gateway outputs missing or empty" "reason explained"
expect_not_log "stacks/01-zia-url-policy apply" "policy not applied without wiring"
expect_not_log "stacks/03-account-greenfield apply" "workloads not applied without wiring"

EXTRA_ENV=(AUTO_APPROVE=1 'STUB_OUTPUT_JSON=not json')
run_deploy t1 wire
expect_rc 1 "unreadable gateway outputs fail cleanly"
expect_out "not valid JSON" "bad output explained"
if printf '%s' "$OUT" | grep -q Traceback; then fail "no traceback on bad outputs"; else ok "no traceback on bad outputs"; fi

# 5. plan before the gateway exists skips workloads
EXTRA_ENV=()
run_deploy t1 plan
expect_rc 0 "plan before gateway succeeds"
expect_out "03-account-greenfield@app1: skipped - no gateway wiring" "workload plan skipped with reason"
expect_log "stacks/02-ztgw plan" "gateway planned"
expect_log "stacks/01-zia-url-policy plan" "policy planned"

# 6. GATEWAY=false uses existing wiring and never touches 02-ztgw
EXTRA_ENV=(AUTO_APPROVE=1 "STUB_OUTPUT_JSON=$GATEWAY_OUTPUTS")
run_deploy t1 wire
expect_rc 0 "wire succeeds"
write_deploy 'WORKLOADS="03-account-greenfield@app1"'
run_deploy t1 up
expect_rc 0 "workload-only up succeeds"
expect_not_log "stacks/02-ztgw" "gateway untouched when GATEWAY=false"
expect_log "stacks/03-account-greenfield apply" "workload applied"

# 7. down: typed confirmation
write_deploy "$FULL_DEPLOY"
EXTRA_ENV=()
STDIN_TEXT="wrong"$'\n'
run_deploy t1 down
expect_rc 1 "down aborts on wrong confirmation"
expect_not_log "destroy" "nothing destroyed after aborted confirmation"
STDIN_TEXT=""

# 8. down: reverse order, brownfield restore, wiring removed
EXTRA_ENV=(AUTO_APPROVE=1 'STUB_STATE_LIST=aws_route.default["usw2-az1"]')
run_deploy t1 down
expect_rc 0 "down succeeds"
expect_order "down: workloads reversed, then policy, then gateway" \
    "stacks/03-account-brownfield destroy" "stacks/03-account-greenfield destroy" \
    "stacks/01-zia-url-policy destroy" "stacks/02-ztgw destroy"
expect_log "stacks/03-account-brownfield apply .*-var=cutover=false" "brownfield routes restored during down"
if ls "$R"/stacks/*/env/t1.wiring.tfvars.json >/dev/null 2>&1; then
    fail "wiring files removed after gateway destroy"
else
    ok "wiring files removed after gateway destroy"
fi

# 9. status
EXTRA_ENV=('STUB_STATE_LIST=a.b
c.d')
run_deploy t1 status
expect_rc 0 "status succeeds"
expect_out "03-account-brownfield@core *t1-core *2" "status shows workload workspace and resource count"
expect_out "02-ztgw *t1 *2" "status shows gateway"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
