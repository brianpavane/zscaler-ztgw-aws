# Architecture

## Goals

- Use the **official** Terraform providers (`zscaler/zia`, `zscaler/ztc`,
  `hashicorp/aws`) for everything they cover.
- Support both Zscaler API frameworks (OneAPI and Legacy) with one switch.
- Keep each phase in its **own stack with its own state**, so onboarding an
  account never touches the gateway or the policy.
- Keep all changes reversible, including changes to existing (brownfield) VPCs.
- Keep credentials out of command lines, `.tfvars` files and Terraform state.

## Phases and how they connect

```
 Phase 1  stacks/01-zia-url-policy           ZIA tenant
 ───────────────────────────────────         ─────────────────────────────
  custom URL categories (allow / block) ──►  URL Filtering policy
  URL filtering rules (allow, block,             scoped to location ▲
                       default BLOCK)                                │
                                                                     │ location_id
 Phase 2  stacks/02-ztgw                     ZTC tenant              │
 ───────────────────────────────────         ─────────────────────── │ ────
  ZT Gateway (region, AZ IDs) ───────────►   gateway + ZIA location ─┘
    allowed via account group  ◄──────┐      endpoint service name ──┐
                                      │                              │
 Phase 3  stacks/03-account-*          │     customer AWS account     │
 ───────────────────────────────────  │     ──────────────────────── ▼ ────
  WDS onboarding: discovery IAM role
  account registration ── member of ──┘      per AZ:
  VPC (greenfield) or existing VPC              endpoint subnet + GWLB endpoint
                                                private subnet(s) + route table
                                                  0.0.0.0/0 ─► same-AZ endpoint
```

### Phase 1: ZIA URL policy (available)

Custom URL categories hold the allow and block lists; up to three URL
filtering rules use them, in this order:

| Order | Rule | Action | Categories | Created when |
|---|---|---|---|---|
| N | `<prefix>-allow` | ALLOW | `<prefix>-allow-urls` | `allowed_urls` not empty |
| N+1 | `<prefix>-block` | BLOCK | `<prefix>-block-urls` | `blocked_urls` not empty |
| N+2 | `<prefix>-default` | BLOCK | `ANY` | `default_action = "BLOCK"` |

N is `rule_order_start` (default 1). Orders stay contiguous when a rule is
not created. URL filtering is first-match, so allow beats block beats default.

ZIA has no editable "default" URL filtering rule; unmatched traffic falls
through to the tenant's other rules, and is allowed if nothing matches.
"Default BLOCK" is therefore an explicit catch-all rule.

**Scoping.** All rules are scoped to the ZT Gateway's ZIA location. ZIA
applies a rule with no location to the whole tenant, so with no location the
rules are created `DISABLED`. The `zia` provider cannot create location
groups, so scoping uses location IDs or names directly.

**v1 limits (by decision):** URL filtering only (no Cloud Firewall default
rule), no SSL inspection. Without SSL inspection ZIA matches HTTPS on the
domain only, so list entries should be domains.

### Phase 2: ZT Gateway (available)

`zscaler/ztc` 0.2.0 and the official Go SDK have **no** Zero Trust Gateway
support, but the Cloud & Branch Connector API documents `/ztGateway`. The
stack uses provider resources for everything around the gateway
(`ztc_location_template`, `ztc_account_groups`). The gateway itself is driven
by `scripts/ztgw/ztgw.py` through `terraform_data` provisioners, and read
back with an `external` data source:

- one standard-library client for OneAPI and Legacy, TLS verified,
  credentials from the environment only (never in state or argv);
- idempotent create (adopts an existing gateway by name in the same region),
  health polling, activation, in-place update of mutable settings, and
  delete with cleanup of the leftover location;
- immutable settings (name, region, AZs, location, template) replace the
  gateway; account settings update it in place.

Outputs: endpoint service name (Phase 3) and location name/ID (Phase 1). See
[phase2-ztgw.md](phase2-ztgw.md).

### Phase 3: account onboarding + VPC (available)

Details: [phase3-account.md](phase3-account.md). WDS onboarding is part of
Phase 3 rather than a separate phase:

1. The account is registered in Partner Integrations (client), and Zscaler
   generates its external ID.
2. A discovery IAM role, equivalent to Zscaler's CloudFormation template
   v1.0.1, trusts Zscaler's role with that external ID. Zscaler then verifies
   it. The template has no EventBridge part, so none is created.
3. The account joins the account group the gateway allows. The gateway
   itself is not modified when accounts are added.
4. VPC side: one endpoint subnet + GWLB endpoint per AZ, one route table per
   AZ with `0.0.0.0/0` pointing to the **same-AZ** endpoint.

AWS credentials are either for the customer account (direct) or for a central
account that assumes a role in it. In both cases the provider is locked to
`aws_account_id`.

Greenfield builds a new VPC. Brownfield attaches to an existing VPC (one route
table per AZ, checked at plan time). It imports each default route, records
its original target, swaps it to the endpoint in place, and restores it on
rollback (`cutover = false`) or destroy.

**To verify in the test tenant:** that account-group membership changes
reach the gateway's endpoint-service allow list without a gateway update,
and that egress needs no NAT/IGW in the customer VPC.

## State and environments

- One Terraform workspace per tenant/env (e.g. `zs2`, `zs3`, `prod`), selected by
  `scripts/run.sh`. Local state in v1 (`terraform.tfstate.d/<env>/`),
  git-ignored. S3 backend with locking in v2.
- Stacks pass values to each other through `tfvars` (for example, the Phase 2
  location ID goes into Phase 1's `location_ids`). Once state moves to S3,
  this can switch to `terraform_remote_state`.

## Activation

ZIA and Cloud & Branch Connector changes are staged until activated, and
activation covers the whole tenant.

- **ZIA:** each ZIA stack ends with `zia_activation_status`, re-created
  whenever the stack's inputs change. After a `destroy`, `scripts/run.sh`
  applies `stacks/zia-activate`.
- **Cloud & Branch Connector:** `ztgw.py` activates after every gateway
  create, update and delete. `terraform_data.ztc_activation` activates
  template and account-group changes. After a `destroy`, `scripts/run.sh`
  runs `ztgw.py activate`.
