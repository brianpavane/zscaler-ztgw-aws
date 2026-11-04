output "public_cloud_account_id" {
  description = "Zscaler ID of the onboarded account (use in Phase 2 account_group_member_ids if not using account_group_id)."
  value       = data.external.account.result.id
}

output "external_id" {
  description = "External ID in the discovery role's trust policy."
  value       = data.external.account.result.external_id
}

output "discovery_role_arn" {
  description = "ARN of the discovery role."
  value       = module.role.role_arn
}

output "trusted_role_arn" {
  description = "Zscaler's role that assumes the discovery role."
  value       = local.trusted_role_arn
}

output "event_forwarding_rule_arns" {
  description = "Map of region to EventBridge forwarding rule ARN (empty when forwarding is off)."
  value       = try(module.event_forwarding[0].rule_arns, {})
}

output "account_group_id" {
  description = "Account group the account was added to (null if none)."
  value       = var.account_group_id
}
