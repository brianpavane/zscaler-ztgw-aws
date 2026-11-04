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
#   shared     files shared by the Phase 3 stacks are identical copies
#   validate   terraform init -backend=false && validate, every module + stack
#   tflint     tflint on every module + stack (.tflint.hcl)
#   test       terraform test (mocked providers) in every dir with tests/
#   examples   validate every stacks/*/env/example.tfvars:
#              - stacks with tests/example/: terraform test -var-file (mocked)
#              - zia-only stacks: real-provider `terraform plan` with credential
#                validation skipped (no tenant needed)
#   python     unit tests for scripts/ztgw/ztgw.py (python3 -I, stdlib only)
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

# Validate each stack's env/example.tfvars without a tenant:
#  - stacks with tests/example/ run that test directory with the example
#    var-file against mocked providers (needed for ztc/aws stacks, whose
#    providers cannot configure without credentials);
#  - zia-only stacks are planned with the real provider and credential
#    validation skipped, which also checks values against real schemas.
step_examples() {
    say "example tfvars plan"
    local d name tmp rc=0 ran=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/stacks"
    ln -s "$REPO_ROOT/modules" "$tmp/modules"
    for d in stacks/*/; do
        d="${d%/}"; name="${d#stacks/}"
        [ -f "$d/env/example.tfvars" ] || continue
        echo "-- $name"
        if [ -d "$d/tests/example" ]; then
            ran=1
            "$TF" -chdir="$d" init -backend=false -input=false >/dev/null || { rc=1; continue; }
            if "$TF" -chdir="$d" test -no-color -test-directory=tests/example \
                    -var-file=env/example.tfvars >"$tmp/$name.test.txt" 2>&1; then
                echo "   mocked apply OK"
            else
                cat "$tmp/$name.test.txt"; rc=1
            fi
            continue
        fi
        if grep -Eqs '^[[:space:]]*provider[[:space:]]+"(ztc|aws)"' "$d"/*.tf; then
            echo "   no tests/example/ and providers cannot plan without credentials"; rc=1; continue
        fi
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

step_python() {
    say "python"
    have python3 || { missing_tool python python3; return; }
    if python3 -I -m py_compile scripts/ztgw/ztgw.py \
        && python3 -I -m unittest discover -s tests/python; then
        record python PASS
    else
        record python FAIL
    fi
}

# Files the two Phase 3 stacks share. They are kept as copies (not symlinks)
# so each stack directory is self-contained; this step keeps them in sync.
# variables.tf / outputs.tf are shared only above the stack-specific marker.
SHARED_PHASE3_FILES="versions.tf providers.tf onboarding.tf"
SHARED_PHASE3_PARTIAL="variables.tf outputs.tf"
SHARED_MARKER="# ---- stack-specific (below this line)"

shared_part() { awk -v m="$SHARED_MARKER" 'index($0, m) == 1 {exit} {print}' "$1"; }

step_shared() {
    say "shared Phase 3 files"
    local f bad=0 g=stacks/03-account-greenfield b=stacks/03-account-brownfield
    for f in $SHARED_PHASE3_FILES; do
        if cmp -s "$g/$f" "$b/$f"; then echo "identical: $f"
        else echo "DIFFERENT: $f"; diff -u "$g/$f" "$b/$f" | head -40; bad=1; fi
    done
    for f in $SHARED_PHASE3_PARTIAL; do
        if ! grep -q "^${SHARED_MARKER}" "$g/$f" || ! grep -q "^${SHARED_MARKER}" "$b/$f"; then
            echo "MISSING MARKER in $f"; bad=1
        elif [ "$(shared_part "$g/$f")" = "$(shared_part "$b/$f")" ]; then
            echo "identical (shared part): $f"
        else
            echo "DIFFERENT (shared part): $f"
            diff -u <(shared_part "$g/$f") <(shared_part "$b/$f") | head -40; bad=1
        fi
    done
    if [ "$bad" = 0 ]; then record shared PASS; else record shared FAIL; fi
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

ALL="fmt shared validate tflint test examples python shell wrapper checkov"
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
