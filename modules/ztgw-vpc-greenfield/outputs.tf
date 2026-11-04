output "vpc_id" {
  description = "ID of the new VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Map of AZ ID to private subnet ID."
  value       = { for k, v in aws_subnet.private : k => v.id }
}

output "private_subnet_cidrs" {
  description = "Map of AZ ID to private subnet CIDR."
  value       = local.private_cidrs
}

output "endpoint_subnet_ids" {
  description = "Map of AZ ID to endpoint subnet ID."
  value       = { for k, v in aws_subnet.endpoint : k => v.id }
}

output "private_route_table_ids" {
  description = "Map of AZ ID to private route table ID."
  value       = { for k, v in aws_route_table.private : k => v.id }
}

output "endpoint_ids" {
  description = "Map of AZ ID to GWLB endpoint ID."
  value       = module.endpoints.endpoint_ids
}
