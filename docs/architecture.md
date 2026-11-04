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
  WDS onboarding: IAM role + EventBridge
  ztc_public_cloud_info ── member of ─┘      per AZ:
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

### Phase 2: ZT Gateway (planned)

`zscaler/ztc` 0.2.0 has **no** ZT Gateway resource, so creating and deleting
the gateway needs a direct API call. Everything around it uses provider
resources (`ztc_location_template`, `ztc_account_groups`,
`ztc_supported_regions`). Requirements for the direct-API part:

- one client supporting OneAPI and Legacy, TLS verified, stdlib only;
- credentials passed via environment, never on a command line or in state;
- idempotent create (adopt an existing gateway by name), health polling,
  activation, and delete on destroy;
- clean up the ZIA location left behind by a deleted gateway.

Outputs: endpoint service name, ZIA location ID (input to Phase 1).

### Phase 3: account onboarding + VPC (planned)

WDS onboarding is part of Phase 3 rather than a separate phase:

1. AWS IAM role trusted by the Zscaler AWS account (with external ID), plus
   the EventBridge rule that forwards events to the Zscaler event bus.
2. `ztc_public_cloud_info` registers the account.
3. The account joins the account group the gateway allows. The gateway
   itself is not modified when accounts are added.
4. VPC side: one endpoint subnet + GWLB endpoint per AZ, one route table per
   AZ with `0.0.0.0/0` pointing to the **same-AZ** endpoint.

Greenfield builds a new VPC. Brownfield attaches to an existing VPC (one route
table per AZ assumed). It records each route table's original default-route
target, replaces it with the endpoint, and restores the original target on
destroy instead of deleting the route.

**To verify in the test tenant:** that account-group membership changes
reach the gateway's endpoint-service allow list without a gateway update,
and that egress needs no NAT/IGW in the customer VPC.

## State and environments

- One Terraform workspace per tenant/env (`zs2`, `zs3`), selected by
  `scripts/run.sh`. Local state in v1 (`terraform.tfstate.d/<env>/`),
  git-ignored. S3 backend with locking in v2.
- Stacks pass values to each other through `tfvars` (for example, the Phase 2
  location ID goes into Phase 1's `location_ids`). Once state moves to S3,
  this can switch to `terraform_remote_state`.

## Activation

ZIA (and ZTC) changes are staged until activated, and activation covers the
whole tenant. Each ZIA stack ends with `zia_activation_status`, re-created
whenever the stack's inputs change. Deletions are activated by
`scripts/run.sh` applying `stacks/zia-activate` after a `destroy`.
