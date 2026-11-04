variable "account_name" {
  description = "Name of the AWS account in Zscaler (Partner Integrations). Unique per tenant, max 128 characters."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9 _.-]{0,127}$", var.account_name))
    error_message = "account_name must be 1-128 characters of [A-Za-z0-9 _.-]."
  }
}

variable "aws_account_id" {
  description = "12-digit ID of the AWS account being onboarded."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be 12 digits."
  }
}

variable "discovery_regions" {
  description = "AWS regions Zscaler Workload Discovery scans (e.g. [\"us-west-2\"])."
  type        = list(string)

  validation {
    condition     = length(var.discovery_regions) > 0 && alltrue([for r in var.discovery_regions : can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", r))])
    error_message = "discovery_regions must be a non-empty list of AWS region names."
  }
}

variable "role_name" {
  description = "Name of the discovery role created in the account."
  type        = string
  default     = "ZscalerTagDiscoveryRole"
}

variable "external_id" {
  description = <<-EOT
    External ID for the discovery role's trust policy. null (recommended) =
    Zscaler generates a unique one per account. Set it to share one ID across
    many accounts (e.g. a CloudFormation StackSet); this weakens
    confused-deputy protection.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.external_id == null || (can(regex("^[A-Za-z0-9-]+$", var.external_id)) && try(length(var.external_id) >= 8 && length(var.external_id) <= 1224, false))
    error_message = "external_id must be 8-1224 characters of [A-Za-z0-9-]."
  }
}

variable "zscaler_trusted_role_arn" {
  description = "Zscaler's discovery role. null = read it from the tenant (workloadDiscoverySettings)."
  type        = string
  default     = null

  validation {
    condition     = var.zscaler_trusted_role_arn == null || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.zscaler_trusted_role_arn))
    error_message = "zscaler_trusted_role_arn must be an IAM role ARN or null."
  }
}

variable "account_group_id" {
  description = "Zscaler account group (Phase 2 output account_group_id) to add this account to, so it may connect to the Zero Trust Gateway. null = do not join a group."
  type        = number
  default     = null

  validation {
    condition     = var.account_group_id == null || try(var.account_group_id > 0, false)
    error_message = "account_group_id must be a positive number or null."
  }
}

variable "enable_event_forwarding" {
  description = "Forward discovery events to Zscaler's event bus (EventBridge rule per discovery region). Optional; the discovery role alone is enough for onboarding."
  type        = bool
  default     = false
}

variable "event_bus_arn_template" {
  description = "Zscaler event bus ARN with a <REGION> placeholder. null = read from the account's registration (Event Bus Name)."
  type        = string
  default     = null
}

variable "event_pattern" {
  description = "EventBridge event pattern (JSON) to forward. null = the module's provisional default (EC2 state changes + tag changes)."
  type        = string
  default     = null
}

variable "verify_timeout_seconds" {
  description = "How long to retry Zscaler's verification of the discovery role while IAM propagates."
  type        = number
  default     = 300

  validation {
    condition     = var.verify_timeout_seconds >= 30 && var.verify_timeout_seconds <= 1800
    error_message = "verify_timeout_seconds must be between 30 and 1800."
  }
}

variable "python" {
  description = "Python 3 interpreter that runs scripts/ztgw/ztgw.py."
  type        = string
  default     = "python3"
}

variable "tags" {
  description = "Tags applied to AWS resources."
  type        = map(string)
  default     = {}
}
