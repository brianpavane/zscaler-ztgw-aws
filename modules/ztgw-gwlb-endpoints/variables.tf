variable "name" {
  description = "Name prefix for the endpoints (Name tag: <name>-<az_id>)."
  type        = string
}

variable "vpc_id" {
  description = "VPC that receives the endpoints."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "endpoint_service_name" {
  description = "ZTGW endpoint service name (Phase 2 output endpoint_service_name)."
  type        = string

  validation {
    condition     = can(regex("^com\\.amazonaws\\.vpce\\.[a-z0-9-]+\\.vpce-svc-[0-9a-f]{8,17}$", var.endpoint_service_name))
    error_message = "endpoint_service_name must look like com.amazonaws.vpce.<region>.vpce-svc-<id>."
  }
}

variable "subnet_ids" {
  description = "Map of AZ ID (e.g. usw2-az1) to the subnet that holds that AZ's endpoint. One endpoint per entry."
  type        = map(string)

  validation {
    condition     = length(var.subnet_ids) > 0 && alltrue([for k, v in var.subnet_ids : can(regex("^[a-z]{2,4}[0-9]-az[0-9]+$", k)) && can(regex("^subnet-[0-9a-f]{8,17}$", v))])
    error_message = "subnet_ids must be a non-empty map of AZ ID (usw2-az1) to subnet ID (subnet-...)."
  }
}

variable "tags" {
  description = "Tags applied to every endpoint."
  type        = map(string)
  default     = {}
}
