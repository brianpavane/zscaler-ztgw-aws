# -----------------------------------------------------------------------------
# Phase 1 - ZIA URL filtering policy
#
# Builds the allow/block URL policy and (once a location is known) scopes it
# to the ZT Gateway location from Phase 2. Run through scripts/run.sh:
#
#   scripts/run.sh <env> 01-zia-url-policy plan
#   scripts/run.sh <env> 01-zia-url-policy apply
# -----------------------------------------------------------------------------

data "zia_location_management" "scope" {
  for_each = toset(var.location_names)
  name     = each.value
}

locals {
  location_ids = distinct(concat(
    var.location_ids,
    [for n in var.location_names : data.zia_location_management.scope[n].id],
  ))
}

module "url_policy" {
  source = "../../modules/zia-url-policy"

  name_prefix      = var.name_prefix
  allowed_urls     = var.allowed_urls
  blocked_urls     = var.blocked_urls
  default_action   = var.default_action
  rule_order_start = var.rule_order_start
  location_ids     = local.location_ids
}

# zia_activation_status only activates when it is created, so tie its
# lifecycle to everything that defines the policy: any change re-creates it
# and therefore re-activates.
resource "terraform_data" "policy_fingerprint" {
  input = sha256(jsonencode({
    allowed_urls   = var.allowed_urls
    blocked_urls   = var.blocked_urls
    default_action = var.default_action
    location_names = var.location_names
    location_ids   = var.location_ids
    order          = var.rule_order_start
    name_prefix    = var.name_prefix
  }))
}

resource "zia_activation_status" "this" {
  count  = var.activate ? 1 : 0
  status = "ACTIVE"

  depends_on = [module.url_policy]

  lifecycle {
    replace_triggered_by = [terraform_data.policy_fingerprint]
  }
}

check "policy_is_scoped" {
  assert {
    condition     = length(var.location_names) + length(var.location_ids) > 0
    error_message = "location_names and location_ids are both empty, so the URL filtering rules are staged (DISABLED). After Phase 2, set location_names (or location_ids) to the ZT Gateway location and re-apply to enable them."
  }
}
