# zscaler-ztgw-aws

Terraform automation for **Zscaler Zero Trust Gateway (ZTGW) on AWS**, built
on the official providers:

| Provider | Used for |
|---|---|
| [`zscaler/zia`](https://registry.terraform.io/providers/zscaler/zia/latest) | URL filtering policy, location lookup, activation |
| [`zscaler/ztc`](https://registry.terraform.io/providers/zscaler/ztc/latest) | Cloud & Branch Connector: location templates, account groups (Phase 2+) |
| [`hashicorp/aws`](https://registry.terraform.io/providers/hashicorp/aws/latest) | VPC, subnets, route tables, GWLB endpoints, WDS discovery role (Phase 3) |

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
| 3. Account onboarding (WDS discovery role, account group) + new VPC: per-AZ subnets/route tables, GWLB endpoints, default route via ZTGW | [`stacks/03-account-greenfield`](stacks/03-account-greenfield) | **Available** |
| 3b. As 3, but in an existing VPC: replace its per-AZ default routes (restored on rollback/destroy) | [`stacks/03-account-brownfield`](stacks/03-account-brownfield) | **Available** |

See [docs/architecture.md](docs/architecture.md) for the full design and how
the phases connect.

## Quick start (Phase 1)

Prerequisites: Terraform **>= 1.7**, bash (macOS 3.2 is fine), Python 3
(Phase 2+), and a ZIA API
client (OneAPI) or API admin + key (Legacy) with URL filtering and activation
permissions. See [docs/authentication.md](docs/authentication.md).

```bash
# 1. Credentials for one tenant (file name = env name)
cp config/example.env config/zs2.env
chmod 600 config/zs2.env
$EDITOR config/zs2.env                      # set ZSCALER_AUTH_MODE + credentials

# 2. Policy inputs for that env
cp stacks/01-zia-url-policy/env/example.tfvars stacks/01-zia-url-policy/env/zs2.tfvars
$EDITOR stacks/01-zia-url-policy/env/zs2.tfvars

# 3. Check credentials are complete, then plan and apply
scripts/run.sh zs2 01-zia-url-policy auth-check
scripts/run.sh zs2 01-zia-url-policy plan
scripts/run.sh zs2 01-zia-url-policy apply
```

On the first apply with no location the rules are created **DISABLED**
(staged): a ZIA rule with no location applies to the whole tenant. Set
`location_names` / `location_ids` to the ZT Gateway location (Phase 2) and
apply again to enable them. Details:
[docs/phase1-zia-url-policy.md](docs/phase1-zia-url-policy.md).

## Quick start (Phase 2)

```bash
cp stacks/02-ztgw/env/example.tfvars stacks/02-ztgw/env/zs2.tfvars
$EDITOR stacks/02-ztgw/env/zs2.tfvars        # region, AZ IDs, allowed accounts
scripts/run.sh zs2 02-ztgw apply             # waits until the gateway is HEALTHY

# Attach the Phase 1 policy to the gateway's location
scripts/run.sh zs2 02-ztgw output location_name
#   -> location_names = ["ztgw-zs2-us-west-2-loc"] in stacks/01-zia-url-policy/env/zs2.tfvars
scripts/run.sh zs2 01-zia-url-policy apply
```

Phase 2 also needs Python 3 (standard library only) for the gateway client.
Details: [docs/phase2-ztgw.md](docs/phase2-ztgw.md).

## Quick start (Phase 3)

```bash
scripts/run.sh zs2 02-ztgw output          # endpoint_service_name, account_group_id, AZs
cp stacks/03-account-greenfield/env/example.tfvars stacks/03-account-greenfield/env/zs2.tfvars
$EDITOR stacks/03-account-greenfield/env/zs2.tfvars   # account, Phase 2 outputs, VPC CIDR
scripts/run.sh zs2 03-account-greenfield apply
```

AWS credentials: `AWS_PROFILE` in `config/zs2.env`, either for the customer
account itself (direct) or for a central account plus `aws_assume_role_arn`
(assume role). The provider refuses any account other than
`aws_account_id`. For an existing VPC use `03-account-brownfield`; its
`destroy` restores the original default routes. Details:
[docs/phase3-account.md](docs/phase3-account.md).

## `scripts/run.sh`

```
scripts/run.sh <env> <stack> <action> [extra terraform args]
  action: auth-check | init | validate | plan | apply | destroy | output | show
```

- Reads `config/<env>.env` (must be mode 600; parsed, never sourced) and
  exports only the selected framework's credentials (OneAPI **or** Legacy)
  as the environment variables the providers read. Secrets never appear on a
  command line, in `.tfvars`, or in Terraform state.
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
modules/zia-url-policy/       Phase 1 module + unit tests
stacks/01-zia-url-policy/     Phase 1 root module (env/<env>.tfvars, tests/)
stacks/02-ztgw/               Phase 2 root module (env/<env>.tfvars, tests/)
stacks/03-account-greenfield/ Phase 3: onboarding + new VPC
stacks/03-account-brownfield/ Phase 3: onboarding + existing VPC (route takeover)
modules/ztgw-account-onboarding/  WDS registration, discovery role, group membership
modules/aws-wds-role/         discovery role (Zscaler template v1.0.1 as Terraform)
modules/ztgw-vpc-greenfield/  VPC, per-AZ subnets and route tables
modules/ztgw-gwlb-endpoints/  one GWLB endpoint per AZ
stacks/zia-activate/          utility stack: activate pending ZIA changes
scripts/ztgw/ztgw.py          Zero Trust Gateway API client (OneAPI + Legacy)
scripts/run.sh                per-env runner (auth switch, workspaces)
scripts/qa.sh                 offline QA suite
scripts/lib/common.sh         shared shell helpers
tests/scripts/test_run.sh     run.sh behaviour tests
tests/python/test_ztgw.py     gateway client unit tests
docs/                         architecture, authentication, phases, QA
```

## License

MIT - see [LICENSE](LICENSE).
