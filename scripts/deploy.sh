#!/usr/bin/env bash
#
# deploy.sh - deploy, plan or remove a complete environment, in phase order.
#
#   scripts/deploy.sh <env> <command>
#
#   command  plan    plan every selected stack
#            up      apply: gateway -> wiring -> URL policy -> workloads
#            down    destroy: workloads (reverse) -> URL policy -> gateway
#            status  resources in state, per stack
#            wire    regenerate the wiring files from the gateway outputs
#
# config/<env>.deploy selects what the environment contains (copy
# config/example.deploy). Each stack still has its own tfvars:
#
#   URL_POLICY=true   Phase 1  stacks/01-zia-url-policy/env/<env>.tfvars
#   GATEWAY=true      Phase 2  stacks/02-ztgw/env/<env>.tfvars
#   WORKLOADS="03-account-greenfield@app1 03-account-brownfield@core"
#                     Phase 3, one entry per AWS account:
#                     stacks/<stack>/env/<env>-<instance>.tfvars
#
# Wiring: after the gateway is applied its outputs are written to
# stacks/<stack>/env/<env>.wiring.tfvars.json - location_names for Phase 1;
# region, endpoint_service_name, availability_zone_ids and
# ztgw_account_group_id for Phase 3. run.sh loads them before the stack's
# tfvars, so anything set in tfvars takes precedence. Nothing is copied by
# hand.
#
# Each step is a scripts/run.sh call, so credentials, workspaces, activation
# and the brownfield route restore work exactly as when run individually.
#
# Environment:
#   AUTO_APPROVE=1    no Terraform prompts; for `down` this also skips the
#                     typed confirmation (CI / unattended)
#   TERRAFORM_BIN, PYTHON_BIN   as for run.sh
#
# Compatible with macOS bash 3.2.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-1}"
}

case "${1:-}" in -h|--help) usage 0 ;; esac
[ $# -eq 2 ] || usage 1

ENV_NAME="$1"; CMD="$2"
valid_name "$ENV_NAME" || die "invalid env name '${ENV_NAME}' (letters, digits, '-', '_')"
case "$CMD" in plan|up|down|status|wire) ;; *) usage 1 ;; esac

RUN="${REPO_ROOT}/scripts/run.sh"
PYTHON="${PYTHON_BIN:-python3}"
P1="01-zia-url-policy"
P2="02-ztgw"

load_deploy_file "${REPO_ROOT}/config/${ENV_NAME}.deploy"

# Validate and collect workloads (Phase 3 stacks, one per account).
WL=()
for w in $WORKLOADS; do
    stack="${w%%@*}"
    inst=""; case "$w" in *@*) inst="${w#*@}" ;; esac
    valid_name "$stack" || die "WORKLOADS: invalid stack in '${w}'"
    if [ "$w" != "$stack" ]; then valid_name "$inst" || die "WORKLOADS: invalid instance in '${w}'"; fi
    [ -f "${REPO_ROOT}/stacks/${stack}/onboarding.tf" ] \
        || die "WORKLOADS: '${stack}' is not a Phase 3 stack (03-account-greenfield, 03-account-brownfield)"
    for seen in ${WL[@]+"${WL[@]}"}; do
        [ "$seen" != "$w" ] || die "WORKLOADS: '${w}' listed twice"
    done
    WL+=("$w")
done

[ "$URL_POLICY" = true ] || [ "$GATEWAY" = true ] || [ ${#WL[@]} -gt 0 ] \
    || die "config/${ENV_NAME}.deploy selects nothing"

STEPS_DONE=()
run() { # stack[@instance] action
    info "==> ${1} ${2}"
    "$RUN" "$ENV_NAME" "$1" "$2"
    STEPS_DONE+=("$1 $2")
}

tfvars_for() { # stack[@instance]
    local stack="${1%%@*}" ws="$ENV_NAME"
    case "$1" in *@*) ws="${ENV_NAME}-${1#*@}" ;; esac
    printf '%s/stacks/%s/env/%s.tfvars' "$REPO_ROOT" "$stack" "$ws"
}

wiring_for() { printf '%s/stacks/%s/env/%s.wiring.tfvars.json' "$REPO_ROOT" "${1%%@*}" "$ENV_NAME"; }

selected() {
    if [ "$GATEWAY" = true ]; then echo "$P2"; fi
    if [ "$URL_POLICY" = true ]; then echo "$P1"; fi
    for w in ${WL[@]+"${WL[@]}"}; do echo "$w"; done
}

preflight() {
    local s missing=0
    while IFS= read -r s; do
        if [ ! -f "$(tfvars_for "$s")" ]; then
            warn "missing $(tfvars_for "$s") (copy env/example.tfvars)"; missing=1
        fi
    done < <(selected)
    [ "$missing" = 0 ] || die "create the missing tfvars files first"
}

# Write the wiring files from the gateway's outputs.
wire() {
    local json
    info "==> wiring: reading ${P2} outputs"
    json="$("$RUN" "$ENV_NAME" "$P2" output -json)" || die "could not read ${P2} outputs"
    printf '%s' "$json" | "$PYTHON" -I -c '
import json, os, sys, tempfile
root, env = sys.argv[1], sys.argv[2]
try:
    out = {k: v.get("value") for k, v in json.load(sys.stdin).items()}
except (ValueError, AttributeError):
    sys.exit("[deploy] 02-ztgw outputs are not valid JSON (terraform output -json)")
need = ("location_name", "endpoint_service_name", "region", "availability_zone_ids")
missing = [k for k in need if not out.get(k)]
if missing:
    sys.exit("[deploy] gateway outputs missing or empty: " + ", ".join(missing) + " (is 02-ztgw applied and HEALTHY?)")
targets = {"01-zia-url-policy": {"location_names": [out["location_name"]]}}
phase3 = {"region": out["region"], "endpoint_service_name": out["endpoint_service_name"],
          "availability_zone_ids": out["availability_zone_ids"]}
if out.get("account_group_id") not in (None, "", 0):
    phase3["ztgw_account_group_id"] = int(out["account_group_id"])
for d in sorted(os.listdir(os.path.join(root, "stacks"))):
    if os.path.isfile(os.path.join(root, "stacks", d, "onboarding.tf")):
        targets[d] = phase3
for stack, values in targets.items():
    envdir = os.path.join(root, "stacks", stack, "env")
    path = os.path.join(envdir, env + ".wiring.tfvars.json")
    fd, tmp = tempfile.mkstemp(dir=envdir, prefix=".wiring.")
    with os.fdopen(fd, "w") as f:
        json.dump(values, f, indent=2, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    print("[deploy] wrote " + os.path.relpath(path, root), file=sys.stderr)
' "$REPO_ROOT" "$ENV_NAME" || die "wiring failed"
}

remove_wiring() {
    local f
    for f in "$REPO_ROOT"/stacks/*/env/"${ENV_NAME}".wiring.tfvars.json; do
        [ -f "$f" ] || continue
        rm -f "$f" && info "removed ${f#"${REPO_ROOT}/"}"
    done
}

summary() {
    local s
    info "completed steps:"
    for s in ${STEPS_DONE[@]+"${STEPS_DONE[@]}"}; do info "  ${s}"; done
}

case "$CMD" in
    wire)
        wire
        ;;
    status)
        printf '%-40s %-28s %s\n' "STACK" "WORKSPACE" "RESOURCES"
        while IFS= read -r s; do
            line="$("$RUN" "$ENV_NAME" "$s" status 2>/dev/null)" || line="$(printf '%s\t?\terror' "$s")"
            IFS="$(printf '\t')" read -r a b c <<< "$line"
            printf '%-40s %-28s %s\n' "$a" "$b" "$c"
        done < <(selected)
        ;;
    plan)
        preflight
        rc=0
        if [ "$GATEWAY" = true ]; then run "$P2" plan || rc=1; fi
        if [ "$URL_POLICY" = true ]; then run "$P1" plan || rc=1; fi
        for w in ${WL[@]+"${WL[@]}"}; do
            if [ ! -f "$(wiring_for "$w")" ]; then
                warn "${w}: skipped - no gateway wiring yet (run: deploy.sh ${ENV_NAME} up, or wire)"
                continue
            fi
            run "$w" plan || rc=1
        done
        summary
        exit "$rc"
        ;;
    up)
        preflight
        if [ "$GATEWAY" = true ]; then
            run "$P2" apply
            wire
        else
            info "GATEWAY=false: using existing wiring files (deploy.sh ${ENV_NAME} wire to refresh)"
        fi
        if [ "$URL_POLICY" = true ]; then run "$P1" apply; fi
        for w in ${WL[@]+"${WL[@]}"}; do
            [ -f "$(wiring_for "$w")" ] || die "${w}: no gateway wiring ($(wiring_for "$w")); deploy the gateway first"
            run "$w" apply
        done
        summary
        ;;
    down)
        preflight
        if [ "${AUTO_APPROVE:-0}" != "1" ]; then
            printf 'This destroys everything in config/%s.deploy:\n' "$ENV_NAME" >&2
            selected | sed 's/^/  /' >&2
            printf 'Type the env name (%s) to continue: ' "$ENV_NAME" >&2
            read -r reply
            [ "$reply" = "$ENV_NAME" ] || die "aborted"
        fi
        # Reverse order: workloads (their endpoints use the gateway), then the
        # policy (its rules reference the gateway location), then the gateway.
        i=${#WL[@]}
        while [ "$i" -gt 0 ]; do
            i=$((i - 1))
            run "${WL[$i]}" destroy
        done
        if [ "$URL_POLICY" = true ]; then run "$P1" destroy; fi
        if [ "$GATEWAY" = true ]; then
            run "$P2" destroy
            remove_wiring
        fi
        summary
        ;;
esac
