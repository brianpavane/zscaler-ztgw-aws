# Shared by stacks/03-account-greenfield and stacks/03-account-brownfield.
# Everything above the stack-specific marker is identical in both stacks
# (scripts/qa.sh shared checks this).

variable "region" {
  description = "AWS region of the workload VPC. Must be the Zero Trust Gateway's region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as us-west-2."
  }
}

variable "aws_account_id" {
  description = "12-digit ID of the customer AWS account. The AWS provider refuses to run against any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be 12 digits."
  }
}

variable "aws_assume_role_arn" {
  description = "Assume-role mode: role in the customer account to assume from the AWS_PROFILE credentials. null = direct mode."
  type        = string
  default     = null

  validation {
    condition     = var.aws_assume_role_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.aws_assume_role_arn))
    error_message = "aws_assume_role_arn must be an IAM role ARN or null."
  }
}

variable "aws_assume_role_external_id" {
  description = "External ID required by aws_assume_role_arn's trust policy, if any."
  type        = string
  default     = null
}

variable "account_name" {
  description = "Name of the account in Zscaler. Default: aws-<aws_account_id>."
  type        = string
  default     = null
}

variable "enable_wds" {
  description = "Onboard the account to Zscaler Workload Discovery (discovery role, registration, group membership)."
  type        = bool
  default     = true
}

variable "discovery_role_name" {
  description = "Name of the Zscaler discovery role created in the account."
  type        = string
  default     = "ZscalerTagDiscoveryRole"
}

variable "discovery_external_id" {
  description = "External ID for the discovery role. null (recommended) = Zscaler generates a unique one. Set to share one ID across accounts (weaker confused-deputy protection)."
  type        = string
  default     = null
}

variable "zscaler_trusted_role_arn" {
  description = "Zscaler's discovery role ARN. null = read from the tenant. Zscaler documents arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole."
  type        = string
  default     = null
}

variable "discovery_regions" {
  description = "Regions Workload Discovery scans. Default: [region]."
  type        = list(string)
  default     = null
}

variable "enable_event_forwarding" {
  description = "Forward discovery events to Zscaler's event bus via EventBridge (one rule per discovery region). Optional."
  type        = bool
  default     = false
}

variable "event_forwarding_pattern" {
  description = "EventBridge event pattern (JSON) to forward. null = provisional default (EC2 state changes + tag changes) until Zscaler's pattern is confirmed."
  type        = string
  default     = null
}

variable "event_bus_arn_template" {
  description = "Zscaler event bus ARN with <REGION> placeholder. null = read from the account registration."
  type        = string
  default     = null
}

variable "ztgw_account_group_id" {
  description = "Phase 2 output account_group_id. The account is added to it so it may connect to the gateway. null = manage access in Phase 2 instead."
  type        = number
  default     = null
}

variable "endpoint_service_name" {
  description = "Phase 2 output endpoint_service_name."
  type        = string

  validation {
    condition     = can(regex("^com\\.amazonaws\\.vpce\\.[a-z0-9-]+\\.vpce-svc-[0-9a-f]{8,17}$", var.endpoint_service_name))
    error_message = "endpoint_service_name must look like com.amazonaws.vpce.<region>.vpce-svc-<id>."
  }
}

variable "availability_zone_ids" {
  description = "AZ IDs to place endpoints in (subset of the gateway's AZs, Phase 2 output availability_zone_ids)."
  type        = list(string)
  default     = ["usw2-az1", "usw2-az2", "usw2-az3"]

  validation {
    condition     = length(var.availability_zone_ids) > 0 && length(distinct(var.availability_zone_ids)) == length(var.availability_zone_ids) && alltrue([for a in var.availability_zone_ids : can(regex("^[a-z]{2,4}[0-9]-az[0-9]+$", a))])
    error_message = "availability_zone_ids must be distinct AZ IDs such as usw2-az1."
  }
}

variable "name" {
  description = "Name prefix for AWS resources. Default: ztgw-<env>-<region>-wl."
  type        = string
  default     = null
}

variable "python" {
  description = "Python 3 interpreter for scripts/ztgw/ztgw.py."
  type        = string
  default     = "python3"
}

variable "tags" {
  description = "Extra tags for every AWS resource."
  type        = map(string)
  default     = {}
}

# ---- stack-specific (below this line) ----------------------------------------

variable "vpc_cidr" {
  description = "IPv4 CIDR of the new VPC (/16 to /22)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_newbits" {
  description = "Bits added to the VPC prefix per private subnet (8 on a /16 gives /24)."
  type        = number
  default     = 8
}
