#!/usr/bin/env bash
#
# run.sh - run a stack of this repo against one tenant/environment.
#
#   scripts/run.sh <env> <stack>[@<instance>] <action> [extra terraform args...]
#
#   env     name of config/<env>.env (any name, e.g. zs2 or prod). Also used as the
#           Terraform workspace (local state per env) and the tfvars file
#           stacks/<stack>/env/<env>.tfvars.
#   stack   directory under stacks/ (e.g. 01-zia-url-policy, zia-activate)
#   @instance  optional, for stacks deployed more than once per env (one
#           per AWS account, e.g. 03-account-greenfield@app1): workspace
#           <env>-<instance>, tfvars env/<env>-<instance>.tfvars
#   action  init | validate | plan | apply | destroy | output | show |
#           status | auth-check
#
# If stacks/<stack>/env/<env>.wiring.tfvars.json exists (written by
# scripts/deploy.sh from the gateway's outputs), it is loaded before the
# tfvars file, so values set in tfvars take precedence.
#
# Environment:
#   AUTO_APPROVE=1    pass -auto-approve to apply/destroy (CI / unattended)
#
# destroy of a brownfield stack (03-account-brownfield) first restores the
# original default routes, releases them from state, then destroys the rest.
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

ENV_NAME="$1"; STACK_ARG="$2"; ACTION="$3"; shift 3

STACK="${STACK_ARG%%@*}"
INSTANCE=""
case "$STACK_ARG" in *@*) INSTANCE="${STACK_ARG#*@}" ;; esac

valid_name "$ENV_NAME" || die "invalid env name '${ENV_NAME}' (letters, digits, '-', '_')"
valid_name "$STACK"    || die "invalid stack name '${STACK}'"
if [ -n "$INSTANCE" ] || [ "$STACK_ARG" != "$STACK" ]; then
    valid_name "$INSTANCE" || die "invalid instance name '${INSTANCE}' (letters, digits, '-', '_')"
fi

# One workspace (state) and one tfvars file per env, or per env + instance.
WORKSPACE="${ENV_NAME}${INSTANCE:+-${INSTANCE}}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
ENV_FILE="${REPO_ROOT}/config/${ENV_NAME}.env"
TFVARS="${STACK_DIR}/env/${WORKSPACE}.tfvars"
WIRING="${STACK_DIR}/env/${ENV_NAME}.wiring.tfvars.json"

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
    tf workspace select -or-create=true "$WORKSPACE" >&2
}

# Build the optional terraform arguments in ARGS. Done in the current shell
# (not a subshell / process substitution) so that die() aborts the run.
ARGS=()
add_var_file() {
    # Stacks that take no variables (e.g. zia-activate) have no env/ directory.
    if [ -d "${STACK_DIR}/env" ]; then
        [ -f "$TFVARS" ] || die "missing ${TFVARS} (copy env/example.tfvars)"
        # Generated values from the gateway first; the operator's tfvars win.
        if [ -f "$WIRING" ]; then ARGS+=("-var-file=${WIRING}"); fi
        ARGS+=("-var-file=${TFVARS}")
    fi
}
add_auto_approve() {
    if [ "${AUTO_APPROVE:-0}" = "1" ]; then ARGS+=("-auto-approve"); fi
}

info "env=${ENV_NAME} stack=${STACK_ARG} workspace=${WORKSPACE} action=${ACTION} auth=${ZSCALER_AUTH_MODE} products=${PRODUCTS:-none}"

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
        # Brownfield stacks took over existing default routes: put the
        # original targets back, stop managing the routes, then destroy the
        # rest, so the customer's routing is left as it was found.
        if stack_manages_routes "$STACK_DIR"; then
            if tf state list 2>/dev/null | grep -q '^aws_route\.default\['; then
                info "restoring the original default routes (cutover=false)"
                tf apply -input=false ${ARGS[@]+"${ARGS[@]}"} -var=cutover=false "$@" \
                    || die "route restore failed; nothing was destroyed"
                info "releasing the restored routes from Terraform state"
                tf state rm aws_route.default >&2
            fi
            ARGS+=("-var=cutover=false" "-var=release_routes=true")
        fi
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
    status)
        tf_init
        n="$(tf state list 2>/dev/null | grep -c . || true)"
        printf '%s\t%s\t%s\n' "$STACK_ARG" "$WORKSPACE" "$n"
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
