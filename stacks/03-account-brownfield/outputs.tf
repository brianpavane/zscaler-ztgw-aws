# Shared by stacks/03-account-greenfield and stacks/03-account-brownfield.
# Everything above the stack-specific marker is identical in both stacks
# (scripts/qa.sh shared checks this).

output "aws_account_id" {
  description = "Customer AWS account."
  value       = var.aws_account_id
}

output "public_cloud_account_id" {
  description = "Zscaler ID of the onboarded account (null if enable_wds = false)."
  value       = try(module.onboarding[0].public_cloud_account_id, null)
}

output "event_forwarding_rule_arns" {
  description = "Map of region to EventBridge forwarding rule ARN (empty when forwarding is off)."
  value       = try(module.onboarding[0].event_forwarding_rule_arns, {})
}

output "discovery_role_arn" {
  description = "Zscaler discovery role in the account."
  value       = try(module.onboarding[0].discovery_role_arn, null)
}

# ---- stack-specific (below this line) ----------------------------------------

output "vpc_id" {
  description = "The existing VPC."
  value       = var.vpc_id
}

output "endpoint_ids" {
  description = "Map of AZ ID to ZTGW (GWLB) endpoint ID."
  value       = module.endpoints.endpoint_ids
}

output "endpoint_subnet_ids" {
  description = "Map of AZ ID to endpoint subnet ID."
  value       = local.endpoint_subnet_ids
}

output "route_table_ids" {
  description = "Map of AZ ID to the route table whose default route is managed."
  value       = var.route_table_ids
}

output "original_default_routes" {
  description = "Recorded original default-route target per AZ (restored on rollback/destroy)."
  value       = { for az, o in terraform_data.original_route : az => [for k, v in o.output : "${k}=${v}" if v != ""] }
}

output "cutover" {
  description = "true when the default routes point at the ZTGW endpoints."
  value       = var.cutover
}
