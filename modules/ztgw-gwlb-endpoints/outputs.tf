output "endpoint_ids" {
  description = "Map of AZ ID to GWLB endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.this : k => v.id }
}
