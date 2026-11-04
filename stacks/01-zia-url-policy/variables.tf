variable "name_prefix" {
  description = "Prefix for every ZIA object created by this stack. Must be unique per policy in the tenant."
  type        = string
}

variable "allowed_urls" {
  description = "Domains to ALLOW (\"example.com\" exact, \".example.com\" domain + subdomains). See modules/zia-url-policy for full syntax."
  type        = list(string)
  default     = []
}

variable "blocked_urls" {
  description = "Domains to BLOCK. Same syntax as allowed_urls."
  type        = list(string)
  default     = []
}

variable "default_action" {
  description = "ALLOW or BLOCK: what happens to traffic from the scoped locations that matches neither list."
  type        = string
  default     = "ALLOW"
}

variable "location_names" {
  description = <<-EOT
    Names of existing ZIA locations to scope the policy to -- normally the
    location created by the ZT Gateway in Phase 2 (stack 02 output
    `location_name`). Leave empty to stage the policy: rules are created
    DISABLED until a location is supplied.
  EOT
  type        = list(string)
  default     = []
}

variable "location_ids" {
  description = "ZIA location IDs to scope the policy to, as an alternative (or in addition) to location_names -- e.g. stack 02 output `location_id`."
  type        = list(number)
  default     = []
}

variable "rule_order_start" {
  description = "ZIA rule order for the first rule of this policy; the rest follow contiguously."
  type        = number
  default     = 1
}

variable "activate" {
  description = "Activate pending ZIA changes at the end of the apply. Disable only if you activate out-of-band (e.g. ziaActivator)."
  type        = bool
  default     = true
}
