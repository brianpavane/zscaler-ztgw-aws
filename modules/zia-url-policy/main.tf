# -----------------------------------------------------------------------------
# ZIA URL filtering policy
#
#   order N    : <prefix>-allow    ALLOW  custom category <prefix>-allow-urls
#   order N+1  : <prefix>-block    BLOCK  custom category <prefix>-block-urls
#   order N+2  : <prefix>-default  BLOCK  ANY   (only when default_action = BLOCK)
#
# Rules that have nothing to match (empty URL list) are not created, and the
# orders of the remaining rules stay contiguous, as ZIA requires.
# -----------------------------------------------------------------------------

locals {
  allowed_urls = [for u in var.allowed_urls : lower(trimspace(u))]
  blocked_urls = [for u in var.blocked_urls : lower(trimspace(u))]

  overlap = setintersection(toset(local.allowed_urls), toset(local.blocked_urls))

  # Entries with a path only work for plain HTTP without SSL inspection.
  path_entries = [for u in concat(local.allowed_urls, local.blocked_urls) : u if strcontains(u, "/")]

  scoped     = length(var.location_ids) > 0
  rule_state = local.scoped ? "ENABLED" : "DISABLED"

  # Build the ordered list of rules that will exist, then derive contiguous orders.
  rule_keys = compact([
    length(local.allowed_urls) > 0 ? "allow" : "",
    length(local.blocked_urls) > 0 ? "block" : "",
    var.default_action == "BLOCK" ? "default" : "",
  ])
  rule_order = { for i, k in local.rule_keys : k => var.rule_order_start + i }
}

resource "zia_url_categories" "allow" {
  count = length(local.allowed_urls) > 0 ? 1 : 0

  configured_name = "${var.name_prefix}-allow-urls"
  description     = var.description
  super_category  = "USER_DEFINED"
  custom_category = true
  type            = "URL_CATEGORY"
  urls            = local.allowed_urls

  lifecycle {
    precondition {
      condition     = length(local.overlap) == 0
      error_message = "These entries appear in both allowed_urls and blocked_urls: ${join(", ", local.overlap)}. Each URL must be in exactly one list."
    }
  }
}

resource "zia_url_categories" "block" {
  count = length(local.blocked_urls) > 0 ? 1 : 0

  configured_name = "${var.name_prefix}-block-urls"
  description     = var.description
  super_category  = "USER_DEFINED"
  custom_category = true
  type            = "URL_CATEGORY"
  urls            = local.blocked_urls

  lifecycle {
    precondition {
      condition     = length(local.overlap) == 0
      error_message = "These entries appear in both allowed_urls and blocked_urls: ${join(", ", local.overlap)}. Each URL must be in exactly one list."
    }
  }
}

resource "zia_url_filtering_rules" "allow" {
  count = contains(local.rule_keys, "allow") ? 1 : 0

  name           = "${var.name_prefix}-allow"
  description    = var.description
  state          = local.rule_state
  action         = "ALLOW"
  order          = local.rule_order["allow"]
  rank           = var.rule_rank
  protocols      = var.protocols
  url_categories = [zia_url_categories.allow[0].id]

  dynamic "locations" {
    for_each = local.scoped ? [1] : []
    content {
      id = var.location_ids
    }
  }
}

resource "zia_url_filtering_rules" "block" {
  count = contains(local.rule_keys, "block") ? 1 : 0

  name           = "${var.name_prefix}-block"
  description    = var.description
  state          = local.rule_state
  action         = "BLOCK"
  order          = local.rule_order["block"]
  rank           = var.rule_rank
  protocols      = var.protocols
  url_categories = [zia_url_categories.block[0].id]

  dynamic "locations" {
    for_each = local.scoped ? [1] : []
    content {
      id = var.location_ids
    }
  }

  # ZIA reorders rules after each write; creating them one at a time in order
  # keeps the reorder deterministic.
  depends_on = [zia_url_filtering_rules.allow]
}

resource "zia_url_filtering_rules" "default" {
  count = contains(local.rule_keys, "default") ? 1 : 0

  name           = "${var.name_prefix}-default"
  description    = "${var.description} - default ${var.default_action} for scoped locations"
  state          = local.rule_state
  action         = "BLOCK"
  order          = local.rule_order["default"]
  rank           = var.rule_rank
  protocols      = var.protocols
  url_categories = ["ANY"]

  dynamic "locations" {
    for_each = local.scoped ? [1] : []
    content {
      id = var.location_ids
    }
  }

  depends_on = [zia_url_filtering_rules.allow, zia_url_filtering_rules.block]
}

check "path_entries_need_ssl_inspection" {
  assert {
    condition     = length(local.path_entries) == 0
    error_message = "These URL entries contain a path and will only match plain HTTP (ZIA sees only the domain of HTTPS traffic without SSL inspection): ${join(", ", local.path_entries)}"
  }
}
