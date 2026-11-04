#!/usr/bin/env bash
# step_* functions are dispatched by name ("step_$s"), which shellcheck
# cannot follow.
# shellcheck disable=SC2317,SC2329
#
# qa.sh - run every offline validation path for this repo.
#
#   scripts/qa.sh [step ...]
#
# Steps (default: all, in this order):
#   fmt        terraform fmt -check -recursive
#   validate   terraform init -backend=false && validate, every module + stack
#   tflint     tflint on every module + stack (.tflint.hcl)
#   test       terraform test (mocked providers) in every dir with tests/
#   examples   real-provider `terraform plan` of every stacks/*/env/example.tfvars
#              with credential validation skipped (no tenant needed)
#   shell      shellcheck on every shell script
#   wrapper    tests/scripts/test_run.sh (run.sh behaviour, stub terraform)
#   checkov    checkov static security scan (.checkov.yaml)
#
# Tools are looked up on PATH; override with TERRAFORM_BIN, TFLINT_BIN,
# CHECKOV_BIN. A missing optional tool (tflint, checkov) is a failure when
# QA_STRICT=1 (CI) and a skipped step otherwise.
#
# Live-tenant validation is separate: see docs/qa.md.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

TF="${TERRAFORM_BIN:-terraform}"
TFLINT="${TFLINT_BIN:-tflint}"
CHECKOV="${CHECKOV_BIN:-checkov}"
STRICT="${QA_STRICT:-0}"

export TF_IN_AUTOMATION=1
export CHECKPOINT_DISABLE=1

RESULTS=()
FAILED=0

say()  { printf '\n==> %s\n' "$*"; }
record() { # step status
    RESULTS+=("$(printf '%-9s %s' "$1" "$2")")
    [ "$2" = "FAIL" ] && FAILED=1
    return 0
}

tf_dirs() {
    local d
    for d in modules/*/ stacks/*/; do
        d="${d%/}"
        ls "$d"/*.tf >/dev/null 2>&1 && printf '%s\n' "$d"
    done
}

have() { command -v "$1" >/dev/null 2>&1; }

missing_tool() { # step tool
    if [ "$STRICT" = "1" ]; then
        echo "required tool '$2' not found"; record "$1" FAIL
    else
        echo "tool '$2' not found - skipping (set QA_STRICT=1 to fail instead)"; record "$1" SKIP
    fi
}

step_fmt() {
    say "fmt"
    if "$TF" fmt -check -recursive -diff; then record fmt PASS; else record fmt FAIL; fi
}

step_validate() {
    say "validate"
    local d rc=0
    while IFS= read -r d; do
        echo "-- $d"
        if ! "$TF" -chdir="$d" init -backend=false -input=false >/dev/null; then
            echo "init failed: $d"; rc=1; continue
        fi
        "$TF" -chdir="$d" validate -no-color || rc=1
    done < <(tf_dirs)
    if [ "$rc" -eq 0 ]; then record validate PASS; else record validate FAIL; fi
}

step_tflint() {
    say "tflint"
    have "$TFLINT" || { missing_tool tflint "$TFLINT"; return; }
    local d rc=0
    "$TFLINT" --init --config="$REPO_ROOT/.tflint.hcl" >/dev/null || rc=1
    while IFS= read -r d; do
        echo "-- $d"
        "$TFLINT" --chdir="$d" --config="$REPO_ROOT/.tflint.hcl" || rc=1
    done < <(tf_dirs)
    if [ "$rc" -eq 0 ]; then record tflint PASS; else record tflint FAIL; fi
}

step_test() {
    say "terraform test"
    local d rc=0
    while IFS= read -r d; do
        [ -d "$d/tests" ] || continue
        echo "-- $d"
        "$TF" -chdir="$d" init -backend=false -input=false >/dev/null || { rc=1; continue; }
        "$TF" -chdir="$d" test -no-color || rc=1
    done < <(tf_dirs)
    if [ "$rc" -eq 0 ]; then record test PASS; else record test FAIL; fi
}

# Plan each stack's example.tfvars with the real providers but no credentials.
# Catches tfvars/variable mismatches, type errors and validation failures
# against the real provider schemas. Only zia supports skipping credential
# validation; stacks whose plan needs live API reads are listed in
# EXAMPLES_SKIP with a reason.
EXAMPLES_SKIP=""
step_examples() {
    say "example tfvars plan"
    local d name tmp rc=0 ran=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/stacks"
    ln -s "$REPO_ROOT/modules" "$tmp/modules"
    for d in stacks/*/; do
        d="${d%/}"; name="${d#stacks/}"
        [ -f "$d/env/example.tfvars" ] || continue
        case " $EXAMPLES_SKIP " in *" $name "*) echo "-- $name: skipped (EXAMPLES_SKIP)"; continue ;; esac
        echo "-- $name"
        mkdir -p "$tmp/stacks/$name"
        cp "$d"/*.tf "$tmp/stacks/$name/"
        cp "$d/env/example.tfvars" "$tmp/stacks/$name/example.tfvars"
        if grep -Eqs '^[[:space:]]*provider[[:space:]]+"zia"' "$d"/*.tf; then
            printf 'provider "zia" {\n  skip_credentials_validation = true\n}\n' \
                > "$tmp/stacks/$name/providers_override.tf"
        fi
        ran=1
        # Run with a scrubbed environment so no real credentials can be used.
        if ! env -i PATH="$PATH" HOME="$HOME" TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 \
                ${TF_PLUGIN_CACHE_DIR:+TF_PLUGIN_CACHE_DIR="$TF_PLUGIN_CACHE_DIR"} \
                "$TF" -chdir="$tmp/stacks/$name" init -backend=false -input=false >/dev/null; then
            echo "init failed: $name"; rc=1; continue
        fi
        if env -i PATH="$PATH" HOME="$HOME" TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 \
            "$TF" -chdir="$tmp/stacks/$name" plan -input=false -no-color -refresh=false \
            -lock=false -var-file=example.tfvars >"$tmp/$name.plan.txt" 2>&1; then
            echo "   plan OK ($(grep -Eo 'Plan: [0-9]+ to add' "$tmp/$name.plan.txt" || echo 'no changes'))"
        else
            cat "$tmp/$name.plan.txt"; rc=1
        fi
    done
    rm -rf "$tmp"
    if [ "$ran" -eq 0 ]; then record examples SKIP
    elif [ "$rc" -eq 0 ]; then record examples PASS
    else record examples FAIL; fi
}

step_shell() {
    say "shellcheck"
    have shellcheck || { missing_tool shell shellcheck; return; }
    local files
    files="$(git ls-files '*.sh' 2>/dev/null || true)"
    [ -n "$files" ] || files="$(find scripts tests -name '*.sh' -type f)"
    # shellcheck disable=SC2086
    if shellcheck -x -P SCRIPTDIR:. $files; then record shell PASS; else record shell FAIL; fi
}

step_wrapper() {
    say "wrapper tests"
    if bash tests/scripts/test_run.sh; then record wrapper PASS; else record wrapper FAIL; fi
}

step_checkov() {
    say "checkov"
    have "$CHECKOV" || { missing_tool checkov "$CHECKOV"; return; }
    if "$CHECKOV" --config-file .checkov.yaml --directory . --quiet --compact; then
        record checkov PASS
    else
        record checkov FAIL
    fi
}

ALL="fmt validate tflint test examples shell wrapper checkov"
STEPS="${*:-$ALL}"

for s in $STEPS; do
    case " $ALL " in
        *" $s "*) "step_$s" ;;
        *) echo "unknown step '$s' (valid: $ALL)"; exit 2 ;;
    esac
done

printf '\n==> summary\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
exit $FAILED
