# Quality assurance

There are two tiers: an **offline suite** that needs no tenant or credentials
(runs locally and in CI on every change), and a **live integration runbook**
run against a ZS2/ZS3 test tenant before a release.

## Offline suite: `make qa` / `scripts/qa.sh [step...]`

| Step | Tool | What it proves |
|---|---|---|
| `fmt` | `terraform fmt -check` | Canonical formatting |
| `validate` | `terraform validate` | Every module and stack is internally valid against the real provider schemas |
| `tflint` | tflint (`terraform` preset `all`, AWS ruleset) | Naming, typing, documentation, unused declarations, standard module structure |
| `test` | `terraform test` + `mock_provider` | Module and stack behaviour: rule ordering, default action, scoping, staging, input validation, activation wiring |
| `examples` | `terraform plan` (real providers, credential validation skipped, scrubbed env) | Each `env/example.tfvars` matches the stack's variables and passes validation with the real provider |
| `shell` | shellcheck | Shell scripts are free of common bugs |
| `wrapper` | `tests/scripts/test_run.sh` (stub terraform) | `run.sh`: OneAPI/Legacy switching, stale-credential scrubbing, env-file parsing and permissions, name validation, workspaces, var-files, auto-approve, destroy-time activation, no secrets on argv |
| `checkov` | checkov | Static security checks (Terraform, GitHub Actions, committed secrets) |

`QA_STRICT=1` (set in CI) makes a missing optional tool (tflint, checkov) a
failure instead of a skip. Tool paths can be overridden with `TERRAFORM_BIN`,
`TFLINT_BIN`, `CHECKOV_BIN`.

CI (`.github/workflows/ci.yml`) runs the Terraform steps on Terraform
**1.7.5, 1.9.8 and latest**, plus lint, shell and security jobs.
`pre-commit install` adds fmt, tflint, shellcheck, the wrapper tests and
secret/merge-conflict checks to every commit.

### Known gap

`zia_location_management.id` is declared optional (not computed) by the
provider, so mocks cannot fill it. The `location_names` lookup is therefore
covered by the live runbook, not by unit tests. `location_ids` is covered by
unit tests.

## Live integration runbook (Phase 1)

Run once per framework (OneAPI and Legacy) and per cloud (ZS2, ZS3) in a
**test tenant**. Record results in the release PR.

| # | Step | Expected |
|---|---|---|
| 1 | `run.sh <env> 01-zia-url-policy auth-check` | Credentials accepted by the wrapper |
| 2 | `plan` with example lists, no location | Plan shows 2 categories + 3 rules + activation; "staged" warning |
| 3 | `apply` | Objects visible in ZIA Admin Portal; rules **Disabled**; no pending activation |
| 4 | Re-run `plan` | **No changes** (idempotency) |
| 5 | Set `location_names` to a test location, `apply` | Rules **Enabled**, scoped to that location only; activation runs |
| 6 | From the test location: allowed domain, blocked domain, unlisted domain | allow / block / block (with `default_action = BLOCK`) |
| 7 | Switch `default_action = "ALLOW"`, `apply` | Default rule removed; unlisted domain allowed |
| 8 | Add and remove URLs, `apply` | Categories update in place; no rule churn |
| 9 | Same domain in both lists | Plan fails with a clear overlap error |
| 10 | `destroy` | Objects removed, existing rule orders restored, no pending activation |
| 11 | Repeat 1-10 with the other auth mode | Same results |
