output "gateway_name" {
  description = "Name of the Zero Trust Gateway."
  value       = local.gateway_name
}

output "gateway_id" {
  description = "Zscaler ID of the Zero Trust Gateway."
  value       = data.external.gateway.result.id
}

output "region" {
  description = "AWS region of the gateway."
  value       = var.region
}

output "availability_zone_ids" {
  description = "AZ IDs the gateway serves; Phase 3 places one endpoint in each."
  value       = var.availability_zone_ids
}

output "health_status" {
  description = "Gateway health as last read from the API."
  value       = data.external.gateway.result.health_status
}

output "endpoint_service_name" {
  description = "AWS VPC endpoint service name (com.amazonaws.vpce...) - input to Phase 3."
  value       = data.external.gateway.result.endpoint_service_name
}

output "location_name" {
  description = "Location created by the gateway - set as Phase 1 location_names."
  value       = local.location_name
}

output "location_id" {
  description = "ID of the gateway's location (Cloud & Branch Connector)."
  value       = data.external.gateway.result.location_id
}

output "account_group_id" {
  description = "ID of the account group allowed on the gateway (Phase 3 accounts join it)."
  value       = one(ztc_account_groups.consumers[*].group_id)
}

output "account_group_name" {
  description = "Name of the account group allowed on the gateway."
  value       = one(ztc_account_groups.consumers[*].name)
}
