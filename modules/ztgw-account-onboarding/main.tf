# -----------------------------------------------------------------------------
# Onboard an AWS account to Zscaler: Workload Discovery (WDS) + account group.
#
#  1. Zscaler's trusted discovery role: from the tenant (wds-settings) unless
#     zscaler_trusted_role_arn is set.
#  2. Register the account in Partner Integrations (ztgw.py account-register):
#     Zscaler generates the external ID (or external_id is used). The create
#     call can take minutes; the client confirms by lookup.
#  3. Create the discovery role in the account (modules/aws-wds-role), trusting
#     Zscaler's role with that external ID.
#  4. Zscaler verifies the role (wds-verify): every check must be "Allowed".
#     Retries while IAM propagates.
#  5. Add the account to the gateway's account group so it may connect
#     endpoints to the Zero Trust Gateway. Removed again on destroy.
#  6. Optional (enable_event_forwarding): EventBridge rules forwarding
#     discovery events to Zscaler's per-org event bus in each region.
#
# Registration uses the client rather than ztc_public_cloud_info because the
# provider cannot pass an external ID and its create call can outlast the
# API's response time.
# -----------------------------------------------------------------------------

locals {
  client = "${path.module}/../../scripts/ztgw/ztgw.py"

  trusted_role_arn = coalesce(var.zscaler_trusted_role_arn, try(data.external.wds[0].result.trusted_role_arn, null))
}

data "external" "wds" {
  count   = var.zscaler_trusted_role_arn == null ? 1 : 0
  program = [var.python, "-I", local.client, "wds-settings"]
  query   = {}
}

resource "terraform_data" "account" {
  # Changing any of these re-registers the account (new external ID).
  triggers_replace = [var.aws_account_id, var.account_name, var.role_name, var.external_id, sort(var.discovery_regions)]

  input = {
    python_cmd = var.python
    client     = local.client
    spec = jsonencode({
      name           = var.account_name
      aws_account_id = var.aws_account_id
      role_name      = var.role_name
      external_id    = var.external_id
      regions        = sort(var.discovery_regions)
    })
  }

  provisioner "local-exec" {
    command     = "${self.input.python_cmd} -I '${self.input.client}' account-register"
    environment = { ZTGW_ACCOUNT = self.input.spec }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "${self.input.python_cmd} -I '${self.input.client}' account-delete"
    environment = { ZTGW_ACCOUNT = self.input.spec }
  }
}

data "external" "account" {
  program = [var.python, "-I", local.client, "account-read"]
  query   = { aws_account_id = var.aws_account_id }

  depends_on = [terraform_data.account]
}

check "account_registered" {
  assert {
    condition     = data.external.account.result.exists == "true"
    error_message = "AWS account ${var.aws_account_id} is not registered in Zscaler Partner Integrations (deleted outside Terraform?). Re-apply with -replace=module.onboarding[0].terraform_data.account."
  }
}

module "role" {
  source = "../aws-wds-role"

  role_name        = var.role_name
  trusted_role_arn = local.trusted_role_arn
  external_id      = data.external.account.result.external_id
  tags             = var.tags
}

resource "terraform_data" "verify" {
  triggers_replace = [module.role.role_arn, data.external.account.result.external_id, data.external.account.result.id]

  provisioner "local-exec" {
    command = "${var.python} -I '${local.client}' wds-verify"
    environment = {
      ZTGW_WDS = jsonencode({
        public_cloud_account_id = data.external.account.result.id
        role_name               = module.role.role_name
        external_id             = data.external.account.result.external_id
        timeout_seconds         = var.verify_timeout_seconds
      })
    }
  }
}

module "event_forwarding" {
  source = "../aws-wds-event-forwarding"
  count  = var.enable_event_forwarding ? 1 : 0

  name                   = "${var.role_name}-forwarding"
  aws_account_id         = var.aws_account_id
  regions                = var.discovery_regions
  event_bus_arn_template = var.event_bus_arn_template != null ? var.event_bus_arn_template : data.external.account.result.event_bus_name
  event_pattern          = var.event_pattern # null = module's provisional default
  tags                   = var.tags
}

resource "terraform_data" "group_membership" {
  count = var.account_group_id == null ? 0 : 1

  # Destroy provisioners may only use self, so everything they need is input.
  input = {
    python_cmd = var.python
    client     = local.client
    spec = jsonencode({
      group_id                = var.account_group_id
      public_cloud_account_id = data.external.account.result.id
    })
  }

  provisioner "local-exec" {
    command     = "${self.input.python_cmd} -I '${self.input.client}' group-add"
    environment = { ZTGW_GROUP = self.input.spec }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "${self.input.python_cmd} -I '${self.input.client}' group-remove"
    environment = { ZTGW_GROUP = self.input.spec }
  }

  depends_on = [terraform_data.verify]
}
