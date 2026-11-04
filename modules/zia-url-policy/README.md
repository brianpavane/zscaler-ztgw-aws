# Module: zia-url-policy

Creates a ZIA URL filtering policy from an allow list and a block list, plus
an optional default BLOCK catch-all, scoped to one or more ZIA locations.

```hcl
module "url_policy" {
  source = "../../modules/zia-url-policy"

  name_prefix    = "ztgw-prod"
  allowed_urls   = [".github.com"]
  blocked_urls   = [".bad.example"]
  default_action = "BLOCK"
  location_ids   = [123456]
}
```

| Order | Rule | Action | Created when |
|---|---|---|---|
| `rule_order_start` | `<prefix>-allow` | ALLOW | `allowed_urls` not empty |
| next | `<prefix>-block` | BLOCK | `blocked_urls` not empty |
| next | `<prefix>-default` | BLOCK (`ANY`) | `default_action = "BLOCK"` |

With an empty `location_ids` the rules are created `DISABLED`, because an
unscoped ZIA rule applies to the whole tenant. Activation is left to the
caller (see `stacks/01-zia-url-policy`).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | - | Prefix for all objects (1-31 chars). |
| `description` | string | `"Managed by Terraform (zscaler-ztgw-aws)"` | Description on all objects. |
| `allowed_urls` | list(string) | `[]` | Domains to allow (`example.com` exact, `.example.com` with subdomains). |
| `blocked_urls` | list(string) | `[]` | Domains to block. |
| `default_action` | string | `"ALLOW"` | `ALLOW` or `BLOCK`. |
| `location_ids` | list(number) | `[]` | ZIA locations; empty means the rules are DISABLED. |
| `rule_order_start` | number | `1` | Order of the first rule. |
| `rule_rank` | number | `7` | Admin rank 0-7. |
| `protocols` | list(string) | `["ANY_RULE"]` | ZIA protocol criteria. |

## Outputs

| Name | Description |
|---|---|
| `allow_category_id` | Custom ALLOW category ID, or null |
| `block_category_id` | Custom BLOCK category ID, or null |
| `rule_ids` | `{allow, block, default}` → rule ID, for the rules that exist |
| `rule_orders` | `{allow, block, default}` → order |
| `rule_state` | `ENABLED` or `DISABLED` |
| `default_action` | Effective default action |

## Checks

- Validation: URL syntax (no scheme, wildcard or spaces), case-insensitive
  duplicates, `default_action`, `rule_order_start >= 1`, `rule_rank` 0-7,
  protocol values, positive location IDs.
- Precondition: no entry in both lists.
- Warning (`check`): entries with a path only match plain HTTP without SSL
  inspection.

Tests: `terraform -chdir=modules/zia-url-policy test` (15 cases, mocked provider).
