output "role_arn" {
  description = "Role EventBridge assumes to put events on Zscaler's buses."
  value       = aws_iam_role.events.arn
}

output "event_bus_arns" {
  description = "Map of region to Zscaler event bus ARN that events are forwarded to."
  value       = local.bus_arns
}

output "rule_arns" {
  description = "Map of region to EventBridge rule ARN."
  value       = { for r, rule in aws_cloudwatch_event_rule.forward : r => rule.arn }
}
