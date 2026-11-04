output "location_ids" {
  description = "ZIA location IDs the policy is scoped to (from location_ids and resolved location_names)."
  value       = local.location_ids
}

output "allow_category_id" {
  description = "ID of the custom ALLOW URL category."
  value       = module.url_policy.allow_category_id
}

output "block_category_id" {
  description = "ID of the custom BLOCK URL category."
  value       = module.url_policy.block_category_id
}

output "rule_ids" {
  description = "ZIA URL filtering rule IDs keyed by allow/block/default."
  value       = module.url_policy.rule_ids
}

output "rule_orders" {
  description = "ZIA rule orders keyed by allow/block/default."
  value       = module.url_policy.rule_orders
}

output "rule_state" {
  description = "ENABLED when scoped to a location, DISABLED (staged) otherwise."
  value       = module.url_policy.rule_state
}
