variable "name" {
  description = "Name prefix for every resource (Name tags)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$", var.name))
    error_message = "name must be 1-48 characters of [A-Za-z0-9_.-]."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR of the new VPC (/16 to /22)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 22
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /22."
  }
}

variable "availability_zone_ids" {
  description = "AZ IDs to build in. Must be AZs the Zero Trust Gateway serves (Phase 2 output availability_zone_ids)."
  type        = list(string)

  validation {
    condition     = length(var.availability_zone_ids) > 0 && length(var.availability_zone_ids) <= 6 && length(distinct(var.availability_zone_ids)) == length(var.availability_zone_ids) && alltrue([for a in var.availability_zone_ids : can(regex("^[a-z]{2,4}[0-9]-az[0-9]+$", a))])
    error_message = "availability_zone_ids must be 1-6 distinct AZ IDs such as usw2-az1."
  }
}

variable "private_subnet_newbits" {
  description = "Bits added to the VPC prefix for each private subnet (8 on a /16 gives /24)."
  type        = number
  default     = 8

  validation {
    condition     = var.private_subnet_newbits >= 2 && var.private_subnet_newbits <= 12
    error_message = "private_subnet_newbits must be between 2 and 12."
  }
}

variable "endpoint_service_name" {
  description = "ZTGW endpoint service name (Phase 2 output endpoint_service_name)."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
