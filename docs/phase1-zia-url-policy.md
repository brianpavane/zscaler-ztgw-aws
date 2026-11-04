# Phase 1: ZIA URL filtering policy

Stack: [`stacks/01-zia-url-policy`](../stacks/01-zia-url-policy) · Module:
[`modules/zia-url-policy`](../modules/zia-url-policy)

## What it creates

| Object | Name | When |
|---|---|---|
| Custom URL category | `<prefix>-allow-urls` | `allowed_urls` not empty |
| Custom URL category | `<prefix>-block-urls` | `blocked_urls` not empty |
| URL filtering rule (ALLOW) | `<prefix>-allow` | `allowed_urls` not empty |
| URL filtering rule (BLOCK) | `<prefix>-block` | `blocked_urls` not empty |
| URL filtering rule (BLOCK, ANY) | `<prefix>-default` | `default_action = "BLOCK"` |
| Activation | - | `activate = true` (default), on every input change |

## Inputs (`env/<env>.tfvars`)

| Variable | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | - | Prefix for every object; unique per policy. 1-31 chars. |
| `allowed_urls` | list(string) | `[]` | Domains to allow. |
| `blocked_urls` | list(string) | `[]` | Domains to block. |
| `default_action` | string | `"ALLOW"` | `ALLOW` or `BLOCK` for traffic matching neither list. |
| `location_names` | list(string) | `[]` | ZIA locations to scope to, by name. |
| `location_ids` | list(number) | `[]` | ZIA locations to scope to, by ID. |
| `rule_order_start` | number | `1` | Order of the first rule; the others follow contiguously. |
| `activate` | bool | `true` | Activate ZIA changes at the end of apply. |

### URL syntax

| Entry | Matches |
|---|---|
| `example.com` | exactly `example.com` |
| `.example.com` | `example.com` and every subdomain |
| `example.com/path` | only plain HTTP (no SSL inspection in v1); plan shows a warning |

Rejected at plan time: schemes (`https://`), wildcards (`*.`), spaces,
duplicates (case-insensitive), and any entry in both lists. Entries are
trimmed and lower-cased.

## Lifecycle

1. **Stage.** Apply with `location_names = []`. Categories and rules are
   created **DISABLED**, and the plan warns that the policy is staged.
2. **Attach.** With `scripts/deploy.sh` this is automatic: the gateway's
   location is supplied by the wiring file. By hand, after Phase 2, set `location_names` to the gateway's location
   (`scripts/run.sh <env> 02-ztgw output location_name`, for example
   `["ztgw-zs2-us-west-2-loc"]`) and apply. The rules become ENABLED, scoped only to
   that location, and activation runs.
3. **Change lists.** Edit the lists and apply. Categories update in place and
   activation runs again.
4. **Remove.** `scripts/run.sh <env> 01-zia-url-policy destroy`. The rules and
   categories are deleted, then `stacks/zia-activate` activates the deletion.

## Rule order and existing policy

ZIA evaluates URL filtering rules top-down and the first match wins. The
default `rule_order_start = 1` puts this policy above existing rules, but
because it is scoped to the gateway location it does not affect other
traffic. ZIA requires contiguous orders: inserting at 1 shifts existing rules
down, and destroying shifts them back. Use a higher `rule_order_start` if
some tenant-wide rules (for example compliance blocks) must be evaluated
first.

## Limits

- Up to 48 custom URL categories per tenant, and 25,000 custom URLs across
  all categories.
- URL filtering only. Non-web traffic follows the tenant's Cloud Firewall
  policy.
- Without SSL inspection, HTTPS matching uses the domain name only.

## Outputs

`location_ids`, `allow_category_id`, `block_category_id`, `rule_ids`,
`rule_orders`, `rule_state`.
