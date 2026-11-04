output "role_name" {
  description = "Name of the discovery role (template output RoleNameBasic)."
  value       = aws_iam_role.discovery.name
}

output "role_arn" {
  description = "ARN of the discovery role (template output RoleArnBasic)."
  value       = aws_iam_role.discovery.arn
}
