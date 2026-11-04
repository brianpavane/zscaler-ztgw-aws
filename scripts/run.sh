#!/usr/bin/env bash
#
# run.sh - run a stack of this repo against one tenant/environment.
#
#   scripts/run.sh <env> <stack> <action> [extra terraform args...]
#
#   env     name of config/<env>.env (e.g. zs2, zs3). Also used as the
#           Terraform workspace (local state per env) and the tfvars file
#           stacks/<stack>/env/<env>.tfvars.
#   stack   directory under stacks/ (e.g. 01-zia-url-policy, zia-activate)
#   action  init | validate | plan | apply | destroy | output | show | auth-check
#
# Environment:
#   AUTO_APPROVE=1    pass -auto-approve to apply/destroy (CI / unattended)
#   TERRAFORM_BIN     terraform binary to use (default: terraform, >= 1.7)
#   PYTHON_BIN        python 3 used for scripts/ztgw/ztgw.py (default: python3)
#
# Credentials are read from config/<env>.env and exported as the environment
# variables the official zscaler providers read; they never appear on a
# command line or in a .tfvars file.
#
# Compatible with macOS bash 3.2.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

usage() {
    # Print the header comment block (line 3 up to the first non-comment line).
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-1}"
}

case "${1:-}" in -h|--help) usage 0 ;; esac
[ $# -ge 3 ] || usage 1

ENV_NAME="$1"; STACK="$2"; ACTION="$3"; shift 3

valid_name "$ENV_NAME" || die "invalid env name '${ENV_NAME}' (letters, digits, '-', '_')"
valid_name "$STACK"    || die "invalid stack name '${STACK}'"

STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
ENV_FILE="${REPO_ROOT}/config/${ENV_NAME}.env"
TFVARS="${STACK_DIR}/env/${ENV_NAME}.tfvars"

[ -d "$STACK_DIR" ] || die "unknown stack '${STACK}' (no ${STACK_DIR})"

TF="${TERRAFORM_BIN:-terraform}"
require_terraform "$TF"

PRODUCTS="$(stack_products "$STACK_DIR")"
PYTHON="${PYTHON_BIN:-python3}"

load_env_file "$ENV_FILE"
configure_zscaler_auth "$PRODUCTS"

tf() { "$TF" -chdir="$STACK_DIR" "$@"; }

tf_init() {
    tf init -input=false >&2
    tf workspace select -or-create=true "$ENV_NAME" >&2
}

# Build the optional terraform arguments in ARGS. Done in the current shell
# (not a subshell / process substitution) so that die() aborts the run.
ARGS=()
add_var_file() {
    # Stacks that take no variables (e.g. zia-activate) have no env/ directory.
    if [ -d "${STACK_DIR}/env" ]; then
        [ -f "$TFVARS" ] || die "missing ${TFVARS} (copy env/example.tfvars)"
        ARGS+=("-var-file=${TFVARS}")
    fi
}
add_auto_approve() {
    if [ "${AUTO_APPROVE:-0}" = "1" ]; then ARGS+=("-auto-approve"); fi
}

info "env=${ENV_NAME} stack=${STACK} action=${ACTION} auth=${ZSCALER_AUTH_MODE} products=${PRODUCTS:-none}"

case "$ACTION" in
    auth-check)
        info "credentials for auth mode '${ZSCALER_AUTH_MODE}' are present"
        ;;
    init)
        tf_init
        ;;
    validate)
        tf init -input=false -backend=false >&2
        tf validate
        ;;
    plan)
        add_var_file
        tf_init
        tf plan -input=false ${ARGS[@]+"${ARGS[@]}"} "$@"
        ;;
    apply)
        add_var_file
        add_auto_approve
        tf_init
        if [ "$STACK" = "zia-activate" ]; then
            ARGS+=("-replace=zia_activation_status.this")
        fi
        tf apply -input=false ${ARGS[@]+"${ARGS[@]}"} "$@"
        ;;
    destroy)
        add_var_file
        add_auto_approve
        tf_init
        tf destroy -input=false ${ARGS[@]+"${ARGS[@]}"} "$@"
        # Deletions are not activated by the stack being destroyed.
        if in_list zia "$PRODUCTS" && [ "$STACK" != "zia-activate" ]; then
            info "activating ZIA deletions"
            AUTO_APPROVE=1 "${BASH_SOURCE[0]}" "$ENV_NAME" zia-activate apply
        fi
        if in_list ztc "$PRODUCTS"; then
            info "activating Cloud & Branch Connector deletions"
            "$PYTHON" -I "${REPO_ROOT}/scripts/ztgw/ztgw.py" activate
        fi
        ;;
    output)
        tf_init
        tf output "$@"
        ;;
    show)
        tf_init
        tf show "$@"
        ;;
    *)
        die "unknown action '${ACTION}'"
        ;;
esac
