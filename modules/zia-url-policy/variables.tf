variable "name_prefix" {
  description = "Prefix for every ZIA object this module creates (custom URL categories and URL filtering rules). Keep it unique per policy so objects are easy to find in the ZIA Admin Portal."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9 _.-]{0,30}$", var.name_prefix))
    error_message = "name_prefix must be 1-31 characters: letters, digits, space, '_', '.', '-', and must start with a letter or digit."
  }
}

variable "description" {
  description = "Description stamped on every object this module creates."
  type        = string
  default     = "Managed by Terraform (zscaler-ztgw-aws)"
}

variable "allowed_urls" {
  description = <<-EOT
    Domains/URLs to explicitly ALLOW. Use ZIA custom-category syntax:
      "example.com"   matches exactly example.com
      ".example.com"  matches example.com and every subdomain
    No scheme (http://, https://), no wildcards (*), no spaces.
    Without SSL inspection ZIA only sees the domain of HTTPS traffic, so
    path entries (example.com/foo) only take effect for plain HTTP.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for u in var.allowed_urls :
      can(regex("^\\.?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+(:[0-9]{1,5})?(/[^\\s]*)?$", trimspace(u)))
    ])
    error_message = "Every allowed_urls entry must be a domain such as \"example.com\" or \".example.com\" (optionally followed by a path). Schemes (http://), wildcards (*) and spaces are not allowed."
  }

  validation {
    condition     = length(var.allowed_urls) == length(distinct([for u in var.allowed_urls : lower(trimspace(u))]))
    error_message = "allowed_urls contains duplicate entries (comparison is case-insensitive)."
  }
}

variable "blocked_urls" {
  description = "Domains/URLs to explicitly BLOCK. Same syntax rules as allowed_urls."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for u in var.blocked_urls :
      can(regex("^\\.?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+(:[0-9]{1,5})?(/[^\\s]*)?$", trimspace(u)))
    ])
    error_message = "Every blocked_urls entry must be a domain such as \"example.com\" or \".example.com\" (optionally followed by a path). Schemes (http://), wildcards (*) and spaces are not allowed."
  }

  validation {
    condition     = length(var.blocked_urls) == length(distinct([for u in var.blocked_urls : lower(trimspace(u))]))
    error_message = "blocked_urls contains duplicate entries (comparison is case-insensitive)."
  }
}

variable "default_action" {
  description = <<-EOT
    What happens to traffic from the scoped locations that matches neither list.
      ALLOW - no catch-all rule is created; unmatched traffic falls through to
              the rest of the tenant's URL filtering policy (ZIA's implicit
              behaviour is allow).
      BLOCK - a catch-all BLOCK rule (url_categories = ANY) is created directly
              after the allow/block rules, scoped to the same locations.
  EOT
  type        = string
  default     = "ALLOW"

  validation {
    condition     = contains(["ALLOW", "BLOCK"], var.default_action)
    error_message = "default_action must be \"ALLOW\" or \"BLOCK\"."
  }
}

variable "location_ids" {
  description = <<-EOT
    ZIA location IDs the rules apply to (typically the location created by the
    ZT Gateway in Phase 2). A ZIA rule with NO locations applies to the WHOLE
    tenant, so when this list is empty the rules are created DISABLED (staged)
    and only become active once at least one location is supplied.
  EOT
  type        = list(number)
  default     = []

  validation {
    condition     = alltrue([for id in var.location_ids : id != null ? (id > 0 && floor(id) == id) : false])
    error_message = "location_ids must be positive whole numbers (a null usually means a location name did not resolve)."
  }
}

variable "rule_order_start" {
  description = "ZIA rule order for the first rule this module creates. The remaining rules follow contiguously. ZIA evaluates URL filtering rules top-down, first match wins; 1 places this policy above every existing rule for the scoped locations."
  type        = number
  default     = 1

  validation {
    condition     = var.rule_order_start >= 1 && floor(var.rule_order_start) == var.rule_order_start
    error_message = "rule_order_start must be a whole number >= 1."
  }
}

variable "rule_rank" {
  description = "ZIA admin rank (0-7) stamped on the rules. 7 is the default for rules created by a super admin / API client."
  type        = number
  default     = 7

  validation {
    condition     = var.rule_rank >= 0 && var.rule_rank <= 7 && floor(var.rule_rank) == var.rule_rank
    error_message = "rule_rank must be a whole number between 0 and 7."
  }
}

variable "protocols" {
  description = "Protocols the rules match. ANY_RULE covers HTTP, HTTPS and the other web protocols ZIA inspects."
  type        = list(string)
  default     = ["ANY_RULE"]

  validation {
    condition = length(var.protocols) > 0 && alltrue([
      for p in var.protocols : contains([
        "ANY_RULE", "HTTP_RULE", "HTTPS_RULE", "FOHTTP_RULE", "FTP_RULE", "SSL_RULE",
        "TUNNEL_RULE", "TUNNELSSL_RULE", "HTTP_PROXY", "DOHTTPS_RULE",
        "WEBSOCKET_RULE", "WEBSOCKETSSL_RULE", "TCP_RULE", "UDP_RULE",
      ], p)
    ])
    error_message = "protocols must be a non-empty list of ZIA protocol values, e.g. [\"ANY_RULE\"]."
  }
}
