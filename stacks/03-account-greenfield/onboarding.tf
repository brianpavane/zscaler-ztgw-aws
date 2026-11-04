# Shared by stacks/03-account-greenfield and stacks/03-account-brownfield.
# Keep the two copies identical (scripts/qa.sh shared checks this).

locals {
  name         = coalesce(var.name, "ztgw-${terraform.workspace}-${var.region}-wl")
  account_name = coalesce(var.account_name, "aws-${var.aws_account_id}")
}

# Fails the plan early if the Phase 2 account group ID is wrong.
data "ztc_account_groups" "gateway" {
  count = var.enable_wds && var.ztgw_account_group_id != null ? 1 : 0
  id    = var.ztgw_account_group_id
}

module "onboarding" {
  source = "../../modules/ztgw-account-onboarding"
  count  = var.enable_wds ? 1 : 0

  account_name             = local.account_name
  aws_account_id           = var.aws_account_id
  discovery_regions        = coalesce(var.discovery_regions, [var.region])
  role_name                = var.discovery_role_name
  external_id              = var.discovery_external_id
  zscaler_trusted_role_arn = var.zscaler_trusted_role_arn
  account_group_id         = try(data.ztc_account_groups.gateway[0].id, null)
  enable_event_forwarding  = var.enable_event_forwarding
  event_pattern            = var.event_forwarding_pattern
  event_bus_arn_template   = var.event_bus_arn_template
  python                   = var.python
}

check "endpoint_service_region" {
  assert {
    condition     = split(".", var.endpoint_service_name)[3] == var.region
    error_message = "endpoint_service_name is in ${split(".", var.endpoint_service_name)[3]} but region is ${var.region}; endpoints must be in the gateway's region."
  }
}

check "gateway_access" {
  assert {
    condition     = !var.enable_wds || var.ztgw_account_group_id != null
    error_message = "ztgw_account_group_id is not set: make sure this account is allowed on the gateway another way (Phase 2 allowed_account_ids / additional_aws_accounts), or endpoint creation will fail."
  }
}
