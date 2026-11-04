output "allow_category_id" {
  description = "ID of the custom ALLOW URL category (null when allowed_urls is empty)."
  value       = one(zia_url_categories.allow[*].id)
}

output "block_category_id" {
  description = "ID of the custom BLOCK URL category (null when blocked_urls is empty)."
  value       = one(zia_url_categories.block[*].id)
}

output "rule_ids" {
  description = "Map of rule key (allow, block, default) to ZIA URL filtering rule ID, for the rules that exist."
  value = merge(
    { for r in zia_url_filtering_rules.allow : "allow" => r.rule_id },
    { for r in zia_url_filtering_rules.block : "block" => r.rule_id },
    { for r in zia_url_filtering_rules.default : "default" => r.rule_id },
  )
}

output "rule_orders" {
  description = "Map of rule key to the ZIA rule order it occupies."
  value       = local.rule_order
}

output "rule_state" {
  description = "ENABLED when the rules are scoped to at least one location, DISABLED otherwise."
  value       = local.rule_state
}

output "default_action" {
  description = "The effective default action for traffic matching neither list."
  value       = var.default_action
}
