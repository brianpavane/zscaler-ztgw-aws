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

output "discovery_role_arn" {
  description = "Zscaler discovery role in the account."
  value       = try(module.onboarding[0].discovery_role_arn, null)
}

# ---- stack-specific (below this line) ----------------------------------------

output "vpc_id" {
  description = "ID of the new VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Map of AZ ID to private subnet ID."
  value       = module.vpc.private_subnet_ids
}

output "private_route_table_ids" {
  description = "Map of AZ ID to private route table ID."
  value       = module.vpc.private_route_table_ids
}

output "endpoint_ids" {
  description = "Map of AZ ID to ZTGW (GWLB) endpoint ID."
  value       = module.vpc.endpoint_ids
}
