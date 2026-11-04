# Quality assurance

There are two tiers: an **offline suite** that needs no tenant or credentials
(runs locally and in CI on every change), and a **live integration runbook**
run against a test tenant on a Zscaler production cloud before a release.

## Offline suite: `make qa` / `scripts/qa.sh [step...]`

| Step | Tool | What it proves |
|---|---|---|
| `fmt` | `terraform fmt -check` | Canonical formatting |
| `shared` | `cmp` / `diff` | The files shared by the two Phase 3 stacks (`versions.tf`, `providers.tf`, `onboarding.tf`, and the shared part of `variables.tf`/`outputs.tf`) are identical |
| `validate` | `terraform validate` | Every module and stack is internally valid against the real provider schemas |
| `tflint` | tflint (`terraform` preset `all`, AWS ruleset) | Naming, typing, documentation, unused declarations, standard module structure |
| `test` | `terraform test` + `mock_provider` | Module and stack behaviour: rule ordering, default action, scoping, staging, input validation, activation wiring; Phase 3 subnet/CIDR layout, same-AZ default routes, discovery-role trust, onboarding wiring, assume-role inputs, brownfield cutover / rollback / release and every layout check |
| `examples` | zia stacks: `terraform plan` with the real provider, credential validation skipped, scrubbed env. ztc stacks: `terraform test -test-directory=tests/example -var-file=env/example.tfvars` (mocked) | Each `env/example.tfvars` matches the stack's variables and passes validation |
| `python` | `py_compile` + `unittest` (`tests/python`) | Client: OneAPI/Legacy URLs and auth, key obfuscation, token reuse, 401 re-auth, 429/5xx retry (never re-sending a POST), spec validation, create payload, idempotent create/adopt (including after a failed POST), region checks, health timeout, update diffing, delete + location cleanup, WDS settings, account register (generated or shared external ID, slow create, conflicts, duplicates), permission verification (HTTP 200 + `Denied` is a failure), account-group add/remove, external-data output, CLI exit codes, no secrets in output |
| `shell` | shellcheck | Shell scripts are free of common bugs |
| `wrapper` | `tests/scripts/test_run.sh`, `tests/scripts/test_deploy.sh` (stub terraform + python) | `deploy.sh`: config validation, phase order for up/down/plan, preflight, wiring files and their precedence, per-instance workspaces, typed confirmation, brownfield restore during down, status. `run.sh`: OneAPI/Legacy switching, product-aware legacy credentials (zia/ztc), stale-credential scrubbing, env-file parsing (quoted values, inline comments) and permissions, instances, name validation, workspaces, var-files, auto-approve, destroy-time activation (ZIA and ZTC), brownfield destroy (restore → release → destroy, abort on failed restore), no secrets on argv |
| `checkov` | checkov | Static security checks (Terraform, GitHub Actions, committed secrets) |

`QA_STRICT=1` (set in CI) makes a missing optional tool (tflint, checkov) a
failure instead of a skip. Tool paths can be overridden with `TERRAFORM_BIN`,
`TFLINT_BIN`, `CHECKOV_BIN`.

CI (`.github/workflows/ci.yml`) runs the Terraform steps on Terraform
**1.7.5, 1.9.8 and latest**, plus lint, shell and security jobs.
`pre-commit install` adds fmt, tflint, shellcheck, the wrapper tests and
secret/merge-conflict checks to every commit.

### Known gaps

`zia_location_management.id` is declared optional (not computed) by the
provider, so mocks cannot fill it. The `location_names` lookup is therefore
covered by the live runbook, not by unit tests. `location_ids` is covered by
unit tests.

The gateway client is tested against an in-memory fake of the documented API,
and the Phase 2 and 3 stacks run their provisioners as no-ops
(`python = "true"`) in tests. The real request and response shapes are
confirmed by the live runbooks below. The Partner Integrations shapes
(create payload, slow create, permission-status format, trusted role) follow
Zscaler's documented API and a working reference implementation
(`anasshahid1/zscaler-partner-integ-external-id`).

Mock providers cannot import, so the brownfield tests set
`import_existing_routes = false` and plan the routes as new. The `import`
blocks themselves are covered by the Phase 3 runbook (step B2).

## Live integration runbook (Phase 1)

Run once per framework (OneAPI and Legacy) and per production cloud in use
(at minimum the clouds of your target tenants) in a
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

## Live integration runbook (Phase 2)

Run once per framework and per cloud in a **test tenant** with a test AWS
account ID in `additional_aws_accounts`.

| # | Step | Expected |
|---|---|---|
| 1 | `python3 -I scripts/ztgw/ztgw.py regions` (env exported) | `us-west-2` listed |
| 2 | `run.sh <env> 02-ztgw plan` | Template, group, gateway, settings, activation planned |
| 3 | `apply` | Health polling INIT → HEALTHY; outputs show `vpce-svc` endpoint service name and location ID |
| 4 | Re-run `plan` | **No changes**; `gateway_ready` passes |
| 5 | Interrupt during health polling, re-run `apply` | Existing gateway adopted, no duplicate |
| 6 | Change `additional_aws_accounts`, `apply` | Settings updated in place (no replacement); visible in portal |
| 7 | Add a public-cloud-account ID to `account_group_member_ids` | Only the group changes; that account can create an endpoint |
| 8 | Phase 1 `location_names = [<location_name>]`, apply | Rules scoped to the gateway location. Confirm ZTC location ID == ZIA location ID. |
| 9 | `destroy` | Gateway deleted, location deleted, template and group deleted, no pending activation |
| 10 | Re-apply with the same names | Succeeds (no "location name already exists") |
| 11 | Repeat with the other auth mode | Same results |

## Live integration runbook (Phase 3)

Needs a test AWS account. Run greenfield and brownfield once per AWS auth
mode (direct and assume role).

### Greenfield

| # | Step | Expected |
|---|---|---|
| G1 | `plan` with credentials for a **different** account | Fails: account not allowed (`allowed_account_ids`) |
| G2 | `plan` with a wrong `ztgw_account_group_id` | Fails at plan (group not found) |
| G3 | `apply` | Account registered (portal: Partner Integrations), role created, verification passes, account in the gateway's group, activation |
| G4 | Portal: account permission status | Allowed; discovery lists the new VPC and subnets |
| G5 | Endpoints | `available`, one per AZ, in the endpoint subnets |
| G6 | Instance in a private subnet: browse an allowed / blocked / unlisted domain | Phase 1 policy applied (allow / block / default) |
| G7 | Re-run `plan` | **No changes** |
| G8 | Re-apply Phase 2 | Group still contains the account |
| G9 | `destroy` | Account leaves group, registration and role deleted, VPC gone, no pending activation |
| G10 | Repeat with `discovery_external_id` set | Registration uses the shared ID; role trust uses it |
| G11 | `enable_event_forwarding = true`, `apply` | Rule + target per discovery region pointing at the bus shown on the account in the portal; tagging an instance updates the account's last sync / discovered tags promptly |
| G12 | `scripts/deploy.sh <env> up` from scratch with two workloads | Gateway, wiring files, policy attached, both accounts onboarded; `status` lists all; re-run shows no changes |
| G13 | `scripts/deploy.sh <env> down` | Reverse order; brownfield routes restored; wiring files removed |

### Brownfield

Prepare a VPC with one route table per AZ, each with a `0.0.0.0/0` route
(e.g. NAT gateway), and a test instance.

| # | Step | Expected |
|---|---|---|
| B1 | Point a table at the **main** route table, or share one table across AZs | Plan fails with the layout message |
| B2 | `plan` | Shows imports of the default routes and in-place updates to `vpce-...` |
| B3 | `apply` | Routes now target the same-AZ endpoint; `original_default_routes` shows the NAT gateways; instance traffic goes via Zscaler |
| B4 | Re-run `plan` | **No changes** |
| B5 | `cutover = false`, `apply` | Routes back to NAT; endpoints remain |
| B6 | `cutover = true`, `apply` | Routes back to endpoints |
| B7 | `destroy` via `run.sh` | Routes restored to NAT and **still present**; endpoints, endpoint subnets, role and registration removed |
| B8 | Delete state while cut over, then `plan` | Fails: route "already targets endpoint ... not managed here" |
