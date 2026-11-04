# shellcheck shell=bash
#
# common.sh - helpers shared by scripts/*.sh. Source, do not execute.
# Compatible with macOS bash 3.2 (no mapfile, no associative arrays).

MIN_TF_MAJOR=1
MIN_TF_MINOR=7

# Every variable load_env_file accepts. Anything else in an env file is an error,
# which catches typos (e.g. ZSCALER_CLIENTID) before they become auth failures.
ALLOWED_ENV_KEYS="ZSCALER_AUTH_MODE
ZSCALER_CLIENT_ID ZSCALER_CLIENT_SECRET ZSCALER_PRIVATE_KEY ZSCALER_VANITY_DOMAIN ZSCALER_CLOUD
ZIA_USERNAME ZIA_PASSWORD ZIA_API_KEY ZIA_CLOUD
ZTC_USERNAME ZTC_PASSWORD ZTC_API_KEY ZTC_CLOUD
AWS_PROFILE AWS_REGION"

LEGACY_CLOUDS="zscaler zscalerone zscalertwo zscalerthree zscloud zscalerbeta zscalergov zscalerten"

info() { printf '[run] %s\n' "$*" >&2; }
warn() { printf '[run] WARNING: %s\n' "$*" >&2; }
die()  { printf '[run] ERROR: %s\n' "$*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; }

# in_list NEEDLE "WHITESPACE SEPARATED LIST"
in_list() {
    local needle="$1" item
    # Word splitting of the list is intentional.
    # shellcheck disable=SC2086
    for item in $2; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

require_terraform() {
    local tf="$1" ver major minor
    command -v "$tf" >/dev/null 2>&1 || die "terraform not found ('${tf}'); set TERRAFORM_BIN"
    ver="$("$tf" version | head -1 | sed -E 's/^Terraform v([0-9]+)\.([0-9]+).*/\1 \2/')"
    major="${ver% *}"; minor="${ver#* }"
    if [ "$major" -lt "$MIN_TF_MAJOR" ] || { [ "$major" -eq "$MIN_TF_MAJOR" ] && [ "$minor" -lt "$MIN_TF_MINOR" ]; }; then
        die "terraform >= ${MIN_TF_MAJOR}.${MIN_TF_MINOR} required (found ${major}.${minor})"
    fi
}

# Octal permission bits of a file, portable across macOS (BSD stat) and Linux.
file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# load_env_file FILE
#   Parses KEY=VALUE lines (no sourcing, no expansion) and exports each key.
load_env_file() {
    local file="$1" line key value lineno=0 mode

    [ -f "$file" ] || die "missing ${file} (copy config/example.env)"
    mode="$(file_mode "$file")"
    case "$mode" in
        600|400) ;;
        *) die "${file} has mode ${mode}; run: chmod 600 ${file}" ;;
    esac

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # strip leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "${file}:${lineno}: expected KEY=VALUE"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # strip an inline comment only when the value is unquoted
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
            *) value="${value%%[[:space:]]#*}"; value="${value%"${value##*[![:space:]]}"}" ;;
        esac
        in_list "$key" "$ALLOWED_ENV_KEYS" || die "${file}:${lineno}: unknown key '${key}'"
        export "${key}=${value}"
    done < "$file"
}

require_vars() {
    local v missing=""
    for v in "$@"; do
        [ -n "${!v:-}" ] || missing="${missing} ${v}"
    done
    [ -z "$missing" ] || die "missing required setting(s) for auth mode '${ZSCALER_AUTH_MODE}':${missing}"
}

# configure_zscaler_auth
#   Validates the credentials for ZSCALER_AUTH_MODE and leaves exactly one
#   framework's variables in the environment, so the providers cannot pick up
#   a stale credential from the other one.
configure_zscaler_auth() {
    : "${ZSCALER_AUTH_MODE:=oneapi}"
    case "$ZSCALER_AUTH_MODE" in
        oneapi)
            require_vars ZSCALER_CLIENT_ID ZSCALER_VANITY_DOMAIN
            if [ -z "${ZSCALER_CLIENT_SECRET:-}" ] && [ -z "${ZSCALER_PRIVATE_KEY:-}" ]; then
                die "OneAPI needs ZSCALER_CLIENT_SECRET or ZSCALER_PRIVATE_KEY"
            fi
            [ -z "${ZSCALER_CLOUD:-}" ] && unset ZSCALER_CLOUD
            [ -z "${ZSCALER_CLIENT_SECRET:-}" ] && unset ZSCALER_CLIENT_SECRET
            [ -z "${ZSCALER_PRIVATE_KEY:-}" ] && unset ZSCALER_PRIVATE_KEY
            unset ZIA_USERNAME ZIA_PASSWORD ZIA_API_KEY ZIA_CLOUD \
                  ZTC_USERNAME ZTC_PASSWORD ZTC_API_KEY ZTC_CLOUD
            export ZSCALER_USE_LEGACY_CLIENT=false
            ;;
        legacy)
            require_vars ZIA_USERNAME ZIA_PASSWORD ZIA_API_KEY ZIA_CLOUD
            in_list "${ZIA_CLOUD:-}" "$LEGACY_CLOUDS" || die "ZIA_CLOUD '${ZIA_CLOUD:-}' is not one of: ${LEGACY_CLOUDS}"
            if [ -n "${ZTC_CLOUD:-}" ] && ! in_list "$ZTC_CLOUD" "$LEGACY_CLOUDS"; then
                die "ZTC_CLOUD '${ZTC_CLOUD}' is not one of: ${LEGACY_CLOUDS}"
            fi
            unset ZSCALER_CLIENT_ID ZSCALER_CLIENT_SECRET ZSCALER_PRIVATE_KEY \
                  ZSCALER_VANITY_DOMAIN ZSCALER_CLOUD
            export ZSCALER_USE_LEGACY_CLIENT=true
            ;;
        *)
            die "ZSCALER_AUTH_MODE must be 'oneapi' or 'legacy' (got '${ZSCALER_AUTH_MODE}')"
            ;;
    esac
    [ -z "${AWS_PROFILE:-}" ] && unset AWS_PROFILE
    [ -z "${AWS_REGION:-}" ] && unset AWS_REGION
    return 0
}

# stack_uses_provider DIR NAME - true if any .tf in DIR declares provider NAME.
stack_uses_provider() {
    grep -Eqs "^[[:space:]]*provider[[:space:]]+\"$2\"" "$1"/*.tf
}
