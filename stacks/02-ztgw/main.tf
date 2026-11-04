# -----------------------------------------------------------------------------
# Phase 2 - Zscaler Zero Trust Gateway (AWS)
#
# Provider-managed (zscaler/ztc):
#   ztc_location_template.this   template for the gateway's location
#   ztc_account_groups.consumers account group allowed on the gateway
#
# Gateway (no ztc resource exists) - scripts/ztgw/ztgw.py via terraform_data:
#   terraform_data.gateway           create / delete. Replaced when an
#                                    immutable setting changes (name, region,
#                                    AZs, location, template).
#   terraform_data.gateway_settings  update mutable settings (account groups,
#                                    allowed accounts, additional AWS accounts)
#   data.external.gateway            read back endpoint service name, health
#                                    and the location ID for Phase 1 / 3
#
#   scripts/run.sh <env> 02-ztgw plan|apply|destroy
# -----------------------------------------------------------------------------

locals {
  gateway_name  = coalesce(var.gateway_name, "ztgw-${terraform.workspace}-${var.region}")
  location_name = coalesce(var.location_name, "${local.gateway_name}-loc")
  # Relative to the stack directory: Terraform runs local-exec and external
  # programs from there, so the path stays valid in any checkout.
  client = "${path.module}/../../scripts/ztgw/ztgw.py"

  location_template_id = (
    var.existing_location_template_name == null
    ? ztc_location_template.this[0].template_id
    : tonumber(data.ztc_location_template.existing[0].id)
  )

  account_group_ids = distinct(concat(
    ztc_account_groups.consumers[*].group_id,
    var.account_group_ids,
  ))

  # Changing any of these replaces the gateway (delete + create).
  immutable_spec = {
    name                  = local.gateway_name
    region                = var.region
    availability_zone_ids = var.availability_zone_ids
    location_name         = local.location_name
    location_template_id  = local.location_template_id
  }

  # Changing any of these updates the gateway in place.
  mutable_spec = {
    account_group_ids       = sort(local.account_group_ids)
    allowed_account_ids     = sort(var.allowed_account_ids)
    additional_aws_accounts = sort(var.additional_aws_accounts)
  }

  spec = merge(local.immutable_spec, local.mutable_spec, {
    health_timeout_seconds = var.health_timeout_seconds
    cleanup_location       = var.cleanup_location_on_destroy
  })
}

data "ztc_location_template" "existing" {
  count = var.existing_location_template_name == null ? 0 : 1
  name  = var.existing_location_template_name
}

resource "ztc_location_template" "this" {
  count = var.existing_location_template_name == null ? 1 : 0

  name = "${local.gateway_name}-tmpl"
  desc = "Location template for ZT Gateway ${local.gateway_name} (Terraform)"

  template {
    template_prefix     = local.gateway_name
    ofw_enabled         = var.location_template.ofw_enabled
    ips_control         = var.location_template.ips_control
    xff_forward_enabled = var.location_template.xff_forward_enabled
    auth_required       = var.location_template.auth_required
    aup_enabled         = var.location_template.aup_enabled
    caution_enabled     = var.location_template.caution_enabled
  }
}

resource "ztc_account_groups" "consumers" {
  count = var.create_account_group ? 1 : 0

  name        = "${local.gateway_name}-consumers"
  description = "AWS accounts allowed to connect to ZT Gateway ${local.gateway_name} (Terraform)"
  cloud_type  = "AWS"

  dynamic "public_cloud_accounts" {
    for_each = length(var.account_group_member_ids) > 0 ? [1] : []
    content {
      id = var.account_group_member_ids
    }
  }
}

resource "terraform_data" "gateway" {
  # input is what the destroy-time provisioner sees (self.input): the spec
  # plus the command to run. It holds no secrets - credentials come from the
  # environment at run time.
  input            = merge(local.spec, { python_cmd = "${var.python} -I '${local.client}'" })
  triggers_replace = local.immutable_spec

  provisioner "local-exec" {
    command     = "${var.python} -I '${local.client}' create"
    environment = { ZTGW_SPEC = jsonencode(local.spec) }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "${self.input.python_cmd} delete"
    environment = { ZTGW_SPEC = jsonencode(self.input) }
  }

}

resource "terraform_data" "gateway_settings" {
  triggers_replace = local.mutable_spec

  provisioner "local-exec" {
    command     = "${var.python} -I '${local.client}' update"
    environment = { ZTGW_SPEC = jsonencode(local.spec) }
  }

  depends_on = [terraform_data.gateway]

  lifecycle {
    replace_triggered_by = [terraform_data.gateway]
  }
}

# Account-group membership and location-template changes are staged in the
# tenant until activated; the gateway is not touched by them.
resource "terraform_data" "ztc_activation" {
  triggers_replace = {
    template = local.location_template_id
    group    = jsonencode(ztc_account_groups.consumers[*])
  }

  provisioner "local-exec" {
    command = "${var.python} -I '${local.client}' activate"
  }

  depends_on = [terraform_data.gateway_settings]
}

data "external" "gateway" {
  program = [var.python, "-I", local.client, "read"]
  query = {
    name          = local.gateway_name
    location_name = local.location_name
  }

  depends_on = [terraform_data.gateway_settings]
}

check "gateway_ready" {
  assert {
    condition     = data.external.gateway.result.exists == "true" && upper(data.external.gateway.result.health_status) == "HEALTHY"
    error_message = "Gateway ${local.gateway_name} is not HEALTHY (exists=${data.external.gateway.result.exists}, health=${data.external.gateway.result.health_status})."
  }
}

check "consumers_allowed" {
  assert {
    condition     = var.create_account_group || length(var.account_group_ids) + length(var.allowed_account_ids) + length(var.additional_aws_accounts) > 0
    error_message = "No account groups, allowed accounts or additional AWS accounts are set, so no AWS account can create endpoints to this gateway yet."
  }
}
