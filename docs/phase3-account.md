# Phase 3: account onboarding and workload VPC

Stacks: [`stacks/03-account-greenfield`](../stacks/03-account-greenfield)
(new VPC) · [`stacks/03-account-brownfield`](../stacks/03-account-brownfield)
(existing VPC)

Modules: [`ztgw-account-onboarding`](../modules/ztgw-account-onboarding),
[`aws-wds-role`](../modules/aws-wds-role),
[`ztgw-gwlb-endpoints`](../modules/ztgw-gwlb-endpoints),
[`ztgw-vpc-greenfield`](../modules/ztgw-vpc-greenfield)

Both stacks do the same account onboarding. They differ only in the VPC side.

## Account onboarding (Workload Discovery)

WDS onboarding is part of Phase 3 rather than a separate phase. The account is
shared with the gateway through the Phase 2 **account group**, so the gateway
itself never changes when accounts are added or removed.

| Step | How | Where |
|---|---|---|
| 1. Zscaler's trusted discovery role | `ztgw.py wds-settings`, or `zscaler_trusted_role_arn` | Zscaler |
| 2. Register the account (Partner Integrations). Zscaler generates a unique external ID, or uses `discovery_external_id`. | `ztgw.py account-register` | Zscaler |
| 3. Discovery role trusting Zscaler's role with that external ID | `aws_iam_role` + inline policy `TagDiscovery` | customer account |
| 4. Zscaler verifies the role. Every check must be `Allowed`; retried while IAM propagates. | `ztgw.py wds-verify` | Zscaler |
| 5. Add the account to the gateway's account group, and activate | `ztgw.py group-add` | Zscaler |

On destroy, the account leaves the group, the role is deleted, the
registration is removed, and the changes are activated.

### The discovery role

`modules/aws-wds-role` is the Terraform equivalent of Zscaler's CloudFormation
template *"Zscaler Tag discovery service for VPC, Subnet, EC2 and ENI version
1.0.1"* (`zscaler_discovery_role.yaml`):

- **Trust:** Zscaler's role (Zscaler documents
  `arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole`), only with
  `sts:ExternalId` equal to the account's external ID.
- **Permissions:** read-only `ec2:DescribeVpcs`, `DescribeSubnets`,
  `DescribeInstances`, `DescribeNetworkInterfaces`,
  `DescribeIamInstanceProfileAssociations` and `DescribeVpcEndpoints`.

**No EventBridge resources are created.** Zscaler's template (v1.0.1) creates
only the IAM role, and the onboarding API takes no event-bus configuration
from the customer. `eventBusName` is a Zscaler-side attribute of the account.
If Zscaler later publishes an event-forwarding template, it will be added
here.

### Why the client registers the account, not `ztc_public_cloud_info`

- The provider resource can't pass an `externalId` (it is computed only), so
  neither a Zscaler-generated nor a shared external ID can be set on create.
- `POST /publicCloudInfo` can take more than two minutes. The client treats a
  timeout or 5xx as "maybe created" and confirms by lookup instead of sending
  the request again, which would create duplicate entries.
- Registration is idempotent: re-running adopts an existing entry for the same
  AWS account. It refuses if that entry has a different external ID from the
  one requested.

### Shared external ID (optional)

By default every account gets its own Zscaler-generated external ID, which is
the AWS-recommended protection against the confused-deputy problem. Setting
`discovery_external_id` uses one ID for many accounts, for example to deploy
the role with a CloudFormation StackSet. That weakens the protection, so treat
it as a lab or bulk-onboarding convenience.

## AWS authentication: direct or assume-role

| Mode | Set in `env/<env>.tfvars` | Credentials (`config/<env>.env`) |
|---|---|---|
| **Direct** | `aws_account_id` | `AWS_PROFILE` signed in to the customer account |
| **Assume role** | `aws_account_id`, `aws_assume_role_arn`, optionally `aws_assume_role_external_id` | `AWS_PROFILE` for your central account. Terraform assumes the role in the customer account (session `zscaler-ztgw-<env>`). |

In both modes the AWS provider is locked to `aws_account_id`
(`allowed_account_ids`). If the credentials or the assumed role land in any
other account, every plan and apply fails before changing anything.

The role used must be able to manage VPC resources and IAM roles in the
account: EC2/VPC create, modify and delete; `iam:CreateRole`, `PutRolePolicy`,
`DeleteRole` and related actions.

## Greenfield: new VPC

```
VPC 10.20.0.0/16 (no IGW, no NAT: all egress goes via Zscaler)
├─ block 0 (10.20.0.0/24), split into /28s
│   ├─ endpoint subnet usw2-az1  10.20.0.0/28  ─┐  endpoint route table
│   ├─ endpoint subnet usw2-az2  10.20.0.16/28  ├─ (local route only)
│   └─ endpoint subnet usw2-az3  10.20.0.32/28 ─┘
│        each holds one GWLB endpoint → ZTGW endpoint service
├─ private subnet usw2-az1  10.20.1.0/24 → rt usw2-az1: 0.0.0.0/0 → endpoint az1
├─ private subnet usw2-az2  10.20.2.0/24 → rt usw2-az2: 0.0.0.0/0 → endpoint az2
└─ private subnet usw2-az3  10.20.3.0/24 → rt usw2-az3: 0.0.0.0/0 → endpoint az3
```

- **Placement:** subnets are placed by **AZ ID** (`usw2-az1`), never by AZ
  name, so they line up with the gateway's AZs. AZ names map to different
  physical AZs in each AWS account.
- **Sizing:** `vpc_cidr` must be between /16 and /22. Each private subnet is
  `vpc_cidr` plus `private_subnet_newbits` bits (default 8: /24 on a /16).
  The plan fails with a clear message if the layout doesn't fit.
- **Default security group:** locked down (no rules).
- **Flow logs:** not created; they depend on the customer's logging setup.

## Brownfield: existing VPC

Inputs: `vpc_id`, one route table per AZ (`route_table_ids`), and endpoint
subnets, either new ones from free space (`endpoint_subnet_cidrs`, /28
recommended) or existing ones (`endpoint_subnet_ids`).

### Checks (the plan fails before anything changes)

- `route_table_ids` and the endpoint subnets cover exactly
  `availability_zone_ids`.
- Every route table is in `vpc_id`, isn't the VPC **main** route table, has
  subnet associations, and serves **only subnets in its own AZ**. This is the
  "one route table per AZ" assumption.
- New endpoint CIDRs are network addresses inside the VPC's CIDR blocks.
- Existing endpoint subnets are in the right VPC and AZ, and don't use one of
  the route tables being redirected, which would make traffic loop.
- Each route table must already have a `0.0.0.0/0` route.

### Route takeover and restore

1. The existing `0.0.0.0/0` route of each table is **imported**.
2. Its target (IGW, NAT gateway, transit gateway, ENI, peering, ...) is
   recorded once, in state, and shown in the `original_default_routes`
   output.
3. The route is updated **in place** to the AZ's endpoint (EC2
   `ReplaceRoute`), so there is no moment without a default route.

| You want to | Do |
|---|---|
| Roll back routing, keep endpoints | `cutover = false` in tfvars, then `apply` |
| Cut over again | `cutover = true`, `apply` |
| Remove everything | `scripts/run.sh <env> 03-account-brownfield destroy` |

`destroy` through `run.sh` is three steps:
1. Apply with `cutover=false` to restore the original targets.
2. Release the routes from state (`terraform state rm aws_route.default`).
3. Destroy the rest.

The customer's routes are left exactly as they were found. If the restore
fails, nothing is destroyed. Run `terraform destroy` through `run.sh` only;
destroying a brownfield stack with plain `terraform destroy` would **delete**
the default routes.

If state is lost while routes point at the endpoints, the original targets are
unknown. The plan then stops ("already targets endpoint ... not managed here")
instead of recording an endpoint as the original. Restore the routes by hand.

## Inputs (`env/<env>.tfvars`)

Shared by both stacks:

| Variable | Default | Description |
|---|---|---|
| `region` | `us-west-2` | Must be the gateway's region |
| `aws_account_id` | - | Customer account (12 digits) |
| `aws_assume_role_arn` | `null` | Assume-role mode when set |
| `aws_assume_role_external_id` | `null` | If the role's trust policy requires one |
| `endpoint_service_name` | - | Phase 2 output |
| `availability_zone_ids` | `usw2-az1..3` | Subset of the gateway's AZs |
| `ztgw_account_group_id` | `null` | Phase 2 output `account_group_id`; checked at plan time |
| `enable_wds` | `true` | Onboarding on/off |
| `account_name` | `aws-<account id>` | Name in Partner Integrations |
| `discovery_role_name` | `ZscalerTagDiscoveryRole` | Role created in the account |
| `discovery_external_id` | `null` | Shared external ID (see above) |
| `zscaler_trusted_role_arn` | `null` | Skip the tenant lookup |
| `discovery_regions` | `[region]` | Regions WDS scans |
| `name` | `ztgw-<env>-<region>-wl` | Name prefix for AWS resources |
| `tags` | `{}` | Extra tags (default tags include `ManagedBy`, `Project`, `Environment`) |

Greenfield: `vpc_cidr` (`10.0.0.0/16`), `private_subnet_newbits` (`8`).

Brownfield: `vpc_id`, `route_table_ids`, `endpoint_subnet_cidrs` or
`endpoint_subnet_ids`, `cutover` (`true`).

## Connecting the phases

```bash
scripts/run.sh zs2 02-ztgw output
#   endpoint_service_name, availability_zone_ids, account_group_id
cp stacks/03-account-greenfield/env/example.tfvars stacks/03-account-greenfield/env/zs2.tfvars
$EDITOR stacks/03-account-greenfield/env/zs2.tfvars
scripts/run.sh zs2 03-account-greenfield plan
scripts/run.sh zs2 03-account-greenfield apply
```

Phase 2's account group ignores membership changes after creation, so
re-applying Phase 2 never removes accounts that Phase 3 added.

## Outputs

Both stacks: `aws_account_id`, `public_cloud_account_id`,
`discovery_role_arn`.

Greenfield: `vpc_id`, `private_subnet_ids`, `private_route_table_ids`,
`endpoint_ids`.

Brownfield: `vpc_id`, `endpoint_ids`, `endpoint_subnet_ids`,
`route_table_ids`, `original_default_routes`, `cutover`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `discovery role verification failed ... assumeRole=Denied` | The role's trust policy doesn't match Zscaler's role or external ID, or IAM is still propagating (raise `verify_timeout_seconds`). |
| Endpoint creation fails with a permissions/allow-list error | The account isn't allowed on the gateway yet. Check `ztgw_account_group_id`, or use Phase 2 `allowed_account_ids`. |
| `Cannot import non-existent remote object` (brownfield) | A route table has no `0.0.0.0/0` route. Add one, or attach that AZ's subnets to a table that has one. |
| `region(s) ... not supported for discovery` | The tenant doesn't list that region for WDS; adjust `discovery_regions`. |
