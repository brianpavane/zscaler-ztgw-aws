# zscaler-ztgw-aws

Terraform automation for **Zscaler Zero Trust Gateway (ZTGW) on AWS**, built
on the official providers:

| Provider | Used for |
|---|---|
| [`zscaler/zia`](https://registry.terraform.io/providers/zscaler/zia/latest) | URL filtering policy, location lookup, activation |
| [`zscaler/ztc`](https://registry.terraform.io/providers/zscaler/ztc/latest) | Cloud & Branch Connector: location templates, account groups (Phase 2+) |
| [`hashicorp/aws`](https://registry.terraform.io/providers/hashicorp/aws/latest) | VPC, subnets, route tables, GWLB endpoints, WDS discovery role, EventBridge forwarding (Phase 3) |

The Zero Trust Gateway and Workload Discovery account registration have no
provider resources; a standard-library client
([`scripts/ztgw/ztgw.py`](scripts/ztgw/ztgw.py)) calls Zscaler's documented
API for them, run by Terraform.

Both Zscaler API frameworks are supported for every phase: **OneAPI**
(ZIdentity OAuth2) and the **Legacy API** (username / password / API key),
selected per tenant with one setting. Supported clouds: every **Zscaler
production cloud**. All of them offer the Zero Trust Gateway:

| Cloud | Legacy cloud name (`ZIA_CLOUD` / `ZTC_CLOUD`) |
|---|---|
| zscaler.net | `zscaler` |
| zscalerone.net (ZS1) | `zscalerone` |
| zscalertwo.net (ZS2) | `zscalertwo` |
| zscalerthree.net (ZS3) | `zscalerthree` |
| zscloud.net | `zscloud` |

With OneAPI no cloud setting is needed for production tenants: the vanity
domain identifies the tenant. With the Legacy API, set the cloud name above.

## Phases

| Phase | Stack | Status |
|---|---|---|
| 1. ZIA URL filtering policy: allow list, block list, default ALLOW/BLOCK | [`stacks/01-zia-url-policy`](stacks/01-zia-url-policy) | **Available** |
| 2. ZT Gateway in AWS (region + AZs), attached to the Phase 1 policy | [`stacks/02-ztgw`](stacks/02-ztgw) | **Available** |
| 3. Account onboarding (WDS discovery role, optional EventBridge forwarding, account group) + new VPC: per-AZ subnets/route tables, GWLB endpoints, default route via ZTGW | [`stacks/03-account-greenfield`](stacks/03-account-greenfield) | **Available** |
| 3b. As 3, but in an existing VPC: replace its per-AZ default routes (restored on rollback/destroy) | [`stacks/03-account-brownfield`](stacks/03-account-brownfield) | **Available** |

See [docs/architecture.md](docs/architecture.md) for the full design and how
the phases connect.

## Quick start: a complete environment

Prerequisites: Terraform **>= 1.7**, bash (macOS 3.2 is fine), Python 3
(standard library only), Zscaler API credentials (OneAPI client or Legacy
admin + key, see [docs/authentication.md](docs/authentication.md)) and an AWS
profile for each account.

```bash
# 1. Credentials and contents of the environment (file name = env name)
cp config/example.env config/zs2.env && chmod 600 config/zs2.env
cp config/example.deploy config/zs2.deploy
$EDITOR config/zs2.env config/zs2.deploy

# 2. Inputs per stack (each has a commented example.tfvars)
cp stacks/01-zia-url-policy/env/example.tfvars     stacks/01-zia-url-policy/env/zs2.tfvars
cp stacks/02-ztgw/env/example.tfvars               stacks/02-ztgw/env/zs2.tfvars
cp stacks/03-account-greenfield/env/example.tfvars stacks/03-account-greenfield/env/zs2-app1.tfvars
$EDITOR stacks/*/env/zs2*.tfvars

# 3. Deploy: gateway -> URL policy -> accounts, outputs wired automatically
scripts/deploy.sh zs2 plan
scripts/deploy.sh zs2 up
scripts/deploy.sh zs2 status
scripts/deploy.sh zs2 down        # reverse order, asks for confirmation
```

`deploy.sh` runs each stack through `scripts/run.sh` and passes the
gateway's outputs (location, endpoint service, AZs, account group) to the
other phases, so nothing is copied by hand. See
[docs/deployment.md](docs/deployment.md).

### Phase details

- [Phase 1: URL policy](docs/phase1-zia-url-policy.md). With no gateway
  location, rules are staged DISABLED, because a ZIA rule with no location
  applies to the whole tenant.
- [Phase 2: Zero Trust Gateway](docs/phase2-ztgw.md). Needs Python 3 for
  the gateway client.
- [Phase 3: accounts and VPCs](docs/phase3-account.md). Greenfield or
  brownfield, direct or assume-role AWS auth, optional EventBridge forwarding.

## `scripts/run.sh`

```
scripts/run.sh <env> <stack>[@<instance>] <action> [extra terraform args]
  action: auth-check | init | validate | plan | apply | destroy | output | show | status
```

- Reads `config/<env>.env` (must be mode 600; parsed, never sourced) and
  exports only the selected framework's credentials (OneAPI **or** Legacy)
  as the environment variables the providers read. Secrets never appear on a
  command line, in `.tfvars`, or in Terraform state.
- `@<instance>` deploys a stack more than once per env (one per AWS account):
  workspace `<env>-<instance>`, tfvars `env/<env>-<instance>.tfvars`.
- Loads the generated `env/<env>.wiring.tfvars.json` (gateway outputs) before
  the stack's tfvars, so tfvars values take precedence.
- Uses Terraform workspace `<env>` and `stacks/<stack>/env/<env>.tfvars`, so
  tenants on different clouds (e.g. env names `zs2` and `zs3`) keep separate
  local state in the same checkout.
- In Legacy mode, only the credentials for the products the stack uses
  (`zia`, `ztc`) are required.
- `destroy` of `03-account-brownfield` first restores the original default
  routes and releases them from state, so they survive the destroy.
- `destroy` is followed by activation (ZIA via `stacks/zia-activate`, Cloud &
  Branch Connector via the gateway client) so the deletions take effect.
- `AUTO_APPROVE=1` for unattended runs.

State is **local** (`stacks/<stack>/terraform.tfstate.d/<env>/`) in v1 and is
git-ignored. Back it up. Moving to an S3 backend is planned for v2.

## Quality checks

```bash
make qa          # or: scripts/qa.sh
```

runs every offline validation path: `fmt`, `validate`, `tflint`,
`terraform test` with mocked providers, a check that the Phase 3 stacks'
shared files match, validation of every
`example.tfvars`, Python unit tests for the gateway client, `shellcheck`,
wrapper behaviour tests and a `checkov` security scan. CI runs the same steps on Terraform 1.7, 1.9 and latest. The
live-tenant integration runbook is in [docs/qa.md](docs/qa.md).

## Repository layout

```
config/example.env            credential template (copy to config/<env>.env)
config/example.deploy         environment contents for deploy.sh
modules/zia-url-policy/       Phase 1 module + unit tests
stacks/01-zia-url-policy/     Phase 1 root module (env/<env>.tfvars, tests/)
stacks/02-ztgw/               Phase 2 root module (env/<env>.tfvars, tests/)
stacks/03-account-greenfield/ Phase 3: onboarding + new VPC
stacks/03-account-brownfield/ Phase 3: onboarding + existing VPC (route takeover)
modules/ztgw-account-onboarding/  WDS registration, discovery role, group membership
modules/aws-wds-role/         discovery role (Zscaler template v1.0.1 as Terraform)
modules/aws-wds-event-forwarding/  optional EventBridge forwarding to Zscaler
modules/ztgw-vpc-greenfield/  VPC, per-AZ subnets and route tables
modules/ztgw-gwlb-endpoints/  one GWLB endpoint per AZ
stacks/zia-activate/          utility stack: activate pending ZIA changes
scripts/ztgw/ztgw.py          Zero Trust Gateway API client (OneAPI + Legacy)
scripts/deploy.sh             whole-environment orchestration (up/down/plan/status)
scripts/run.sh                per-stack runner (auth switch, workspaces)
scripts/qa.sh                 offline QA suite
scripts/lib/common.sh         shared shell helpers
tests/scripts/test_run.sh     run.sh behaviour tests
tests/scripts/test_deploy.sh  deploy.sh behaviour tests
tests/python/test_ztgw.py     gateway client unit tests
docs/                         architecture, authentication, phases, QA
```

## License

MIT - see [LICENSE](LICENSE).
