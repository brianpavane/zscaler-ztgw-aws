variable "region" {
  description = "AWS region for the Zero Trust Gateway. Must be a region the tenant supports for ZTGW (checked by the client before creating)."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as \"us-west-2\"."
  }
}

variable "availability_zone_ids" {
  description = <<-EOT
    AWS Availability Zone IDs (not names) the gateway is deployed in, e.g.
    ["usw2-az1", "usw2-az2", "usw2-az3"]. AZ IDs are the same in every AWS
    account, unlike AZ names (us-west-2a ...). Consumer VPC endpoints (Phase 3)
    can only be placed in these AZs.
  EOT
  type        = list(string)
  default     = ["usw2-az1", "usw2-az2", "usw2-az3"]

  validation {
    condition     = length(var.availability_zone_ids) >= 1 && alltrue([for az in var.availability_zone_ids : can(regex("^[a-z]{2,6}[0-9]-az[0-9]{1,2}$", az))])
    error_message = "availability_zone_ids must be a non-empty list of AZ IDs such as \"usw2-az1\" (AZ IDs, not AZ names like us-west-2a)."
  }

  validation {
    condition     = length(var.availability_zone_ids) == length(distinct(var.availability_zone_ids))
    error_message = "availability_zone_ids contains duplicates."
  }
}

variable "gateway_name" {
  description = "Gateway name. Default: ztgw-<env>-<region> (env = Terraform workspace, set by scripts/run.sh)."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$", var.gateway_name))
    error_message = "gateway_name must be 1-63 characters: letters, digits, '_', '.', '-'."
  }
}

variable "location_name" {
  description = "Name of the location the gateway creates (it becomes the ZIA location Phase 1 scopes to). Must be unique in the tenant. Default: <gateway_name>-loc."
  type        = string
  default     = null

  validation {
    condition     = var.location_name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$", var.location_name))
    error_message = "location_name must be 1-63 characters: letters, digits, '_', '.', '-'."
  }
}

variable "existing_location_template_name" {
  description = "Use this existing Cloud & Branch Connector location template instead of creating one."
  type        = string
  default     = null
}

variable "location_template" {
  description = "Settings for the location template this stack creates (ignored when existing_location_template_name is set)."
  type = object({
    ofw_enabled         = optional(bool, true)
    ips_control         = optional(bool, true)
    xff_forward_enabled = optional(bool, false)
    auth_required       = optional(bool, false)
    aup_enabled         = optional(bool, false)
    caution_enabled     = optional(bool, false)
  })
  default = {}
}

variable "create_account_group" {
  description = <<-EOT
    Create an account group (<gateway_name>-consumers) and allow it on the
    gateway. AWS accounts onboarded in Phase 3 join this group via
    account_group_member_ids, so the gateway itself never changes when
    accounts are added.
  EOT
  type        = bool
  default     = true
}

variable "account_group_member_ids" {
  description = "Initial members of the gateway's account group (Zscaler public-cloud-account IDs), applied only when the group is created. Afterwards the Phase 3 stacks add and remove their own account."
  type        = list(number)
  default     = []
}

variable "account_group_ids" {
  description = "Additional existing account group IDs to allow on the gateway."
  type        = list(number)
  default     = []
}

variable "allowed_account_ids" {
  description = "Zscaler public-cloud-account IDs to allow on the gateway directly (prefer the account group)."
  type        = list(number)
  default     = []
}

variable "additional_aws_accounts" {
  description = "Raw 12-digit AWS account IDs allowed to create endpoints to the gateway without WDS onboarding (useful before Phase 3)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.additional_aws_accounts : can(regex("^[0-9]{12}$", a))])
    error_message = "additional_aws_accounts entries must be 12-digit AWS account IDs (as strings)."
  }
}

variable "health_timeout_seconds" {
  description = "How long create waits for the gateway to become HEALTHY."
  type        = number
  default     = 1800

  validation {
    condition     = var.health_timeout_seconds >= 60 && var.health_timeout_seconds <= 7200
    error_message = "health_timeout_seconds must be between 60 and 7200."
  }
}

variable "cleanup_location_on_destroy" {
  description = "On destroy, also delete the location the gateway leaves behind, so its name can be reused."
  type        = bool
  default     = true
}

variable "python" {
  description = "Python 3 interpreter used to run scripts/ztgw/ztgw.py."
  type        = string
  default     = "python3"
}
