variable "name" {
  description = "Name for the IAM role and EventBridge rules (rule name: <name>, role: <name>-events)."
  type        = string
  default     = "zscaler-wds-forwarding"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,56}$", var.name))
    error_message = "name must be 1-56 characters of [A-Za-z0-9_.-]."
  }
}

variable "aws_account_id" {
  description = "The customer account (used to restrict who may assume the forwarding role)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be 12 digits."
  }
}

variable "regions" {
  description = "Regions whose events are forwarded; a rule is created in each, targeting Zscaler's bus in the same region."
  type        = list(string)

  validation {
    condition     = length(var.regions) > 0 && length(distinct(var.regions)) == length(var.regions) && alltrue([for r in var.regions : can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", r))])
    error_message = "regions must be distinct AWS region names."
  }
}

variable "event_bus_arn_template" {
  description = "Zscaler's event bus ARN with a <REGION> placeholder, as shown on the account in the portal (Event Bus Name), e.g. arn:aws:events:<REGION>:175726779870:event-bus/zscaler-bus-<org>-<cloud>."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:events:<REGION>:[0-9]{12}:event-bus/[A-Za-z0-9._-]+$", var.event_bus_arn_template))
    error_message = "event_bus_arn_template must look like arn:aws:events:<REGION>:<account>:event-bus/<name>. If Zscaler returned none for the account, copy it from the portal (Partner Integrations > AWS > account > Event Bus Name) into event_bus_arn_template."
  }
}

variable "event_pattern" {
  description = <<-EOT
    EventBridge event pattern (JSON) selecting the events Zscaler should
    receive. PROVISIONAL default: EC2 instance state changes and resource tag
    changes. Replace with Zscaler's documented pattern once confirmed.
  EOT
  type        = string
  nullable    = false
  default     = <<-EOT
    {
      "source": ["aws.ec2", "aws.tag"],
      "detail-type": ["EC2 Instance State-change Notification", "Tag Change on Resource"]
    }
  EOT

  validation {
    condition     = can(jsondecode(var.event_pattern)) && can(keys(jsondecode(var.event_pattern)))
    error_message = "event_pattern must be a JSON object."
  }
}

variable "tags" {
  description = "Tags applied to the role and rules."
  type        = map(string)
  default     = {}
}
