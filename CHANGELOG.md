# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `docs/getting-started.md`: step-by-step install and configuration guide
  (tools per OS, Zscaler and AWS credentials, every config file with
  examples, run/check/change/remove, troubleshooting, cheat sheet). Commands
  use shell variables (`ZTGW_ENV`, `ZTGW_ACCOUNT`, `ZTGW_REGION`) so they can
  be copied as-is.
- `scripts/deploy.sh <env> plan|up|down|status|wire`: whole-environment
  orchestration in phase order, driven by `config/<env>.deploy`. Gateway
  outputs are wired into Phases 1 and 3 automatically through generated
  `env/<env>.wiring.tfvars.json` files, and the operator's tfvars take
  precedence. Make targets: `plan`, `up`, `down`, `status` (`ENV=<env>`).
- `run.sh`: `<stack>@<instance>` (one workspace and tfvars per AWS account)
  and a `status` action.
- Optional WDS event forwarding (`enable_event_forwarding`,
  `modules/aws-wds-event-forwarding`): an EventBridge rule per discovery
  region targeting the account's Zscaler event bus (read from the
  registration), with a PutEvents-only role. The event pattern is
  provisional until Zscaler's pattern is confirmed.
- Phase 3: `stacks/03-account-greenfield` (new VPC) and
  `stacks/03-account-brownfield` (existing VPC). Both onboard the account to
  Workload Discovery (registration, discovery role, verification, account
  group membership) and add one GWLB endpoint per AZ, with each AZ's private
  default route going through the Zero Trust Gateway.
- Phase 3 AWS authentication: direct or assume-role, with the provider locked
  to `aws_account_id`.
- Brownfield route takeover: existing default routes are imported, their
  targets recorded and swapped in place. `cutover = false` rolls back, and
  `run.sh destroy` restores the routes and then releases them from state.
  Plan-time checks enforce one route table per AZ.
- Modules: `ztgw-account-onboarding`, `aws-wds-role` (Zscaler discovery-role
  template v1.0.1 as Terraform), `ztgw-vpc-greenfield`, `ztgw-gwlb-endpoints`.
- `ztgw.py`: `wds-settings`, `account-register`, `account-read`,
  `account-delete`, `wds-verify`, `group-add`, `group-remove`.
- QA: a `shared` step that keeps the Phase 3 stacks' common files identical,
  plus Terraform, Python and wrapper tests for all of the above. The
  `terraform test` steps run with AWS and Zscaler credentials removed, so a
  test that reaches a real provider fails locally just as it does in CI.
- Phase 2: `stacks/02-ztgw`. Zero Trust Gateway in AWS (default `us-west-2`,
  `usw2-az1..3`, configurable), with a location template, a consumer account
  group, health polling, in-place updates, and destroy-time location cleanup.
  Outputs feed Phase 1 (location) and Phase 3 (endpoint service name).
- `scripts/ztgw/ztgw.py`: standard-library Cloud & Branch Connector client
  for the documented `/ztGateway` API (OneAPI and Legacy).
- QA: Python client tests, mocked example-tfvars tests for ztc stacks, and
  product-aware wrapper tests.

### Changed
- Phase 2 example tfvars no longer allows a placeholder AWS account
  (`additional_aws_accounts = []`).
- Phase 3 example tfvars no longer set the gateway values (they come from
  wiring), so a copied example cannot override them with placeholders.
- Documentation: supported clouds are all Zscaler production clouds
  (`zscaler`, `zscalerone`, `zscalertwo`, `zscalerthree`, `zscloud`), not
  only ZS2/ZS3. The code already accepted them; tests now cover each one.
- Phase 2: the account group's membership is only seeded by
  `account_group_member_ids` at creation. Afterwards the Phase 3 stacks
  manage it, so re-applying Phase 2 never removes their accounts.
- `run.sh`: Legacy mode requires only the credentials of the products a stack
  uses. `destroy` of a ztc stack activates Cloud & Branch Connector changes.

### Fixed
- Env-file parser: a quoted value followed by an inline comment kept its
  quotes (e.g. `KEY="value"  # note`).
- `ztgw.py` re-sent a POST after a 5xx. A create that succeeded slowly could
  then be duplicated. POSTs are no longer retried on 5xx, and the gateway and
  account creates confirm by lookup.
- `ztgw.py`: socket read timeouts are reported as errors instead of
  tracebacks.
- `run.sh --help` exited with an error.
- Phase 1: `modules/zia-url-policy` and `stacks/01-zia-url-policy`. ZIA URL
  filtering policy with allow and block lists, a default ALLOW/BLOCK action,
  location scoping (staged as DISABLED until scoped) and activation.
- `stacks/zia-activate` utility stack, run automatically after a ZIA
  `destroy`.
- `scripts/run.sh`: per-environment runner with a OneAPI/Legacy auth switch,
  a hardened env-file parser and one workspace per tenant.
- `scripts/qa.sh`: offline QA suite (fmt, validate, tflint, terraform test,
  example plans, shellcheck, wrapper tests, checkov), plus a CI workflow and
  pre-commit hooks.
- Documentation: architecture, authentication, Phase 1, QA.
