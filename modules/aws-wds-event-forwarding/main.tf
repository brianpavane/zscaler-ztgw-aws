# -----------------------------------------------------------------------------
# Optional Workload Discovery event forwarding.
#
# For each region: an EventBridge rule on the account's default bus matching
# var.event_pattern, targeting Zscaler's per-org event bus in the same region
# (event_bus_arn_template with <REGION> replaced). EventBridge assumes a role
# that may only PutEvents to those buses.
#
# The discovery role alone is enough for onboarding; forwarding lets Zscaler
# react to changes as they happen instead of on its next sync.
# -----------------------------------------------------------------------------

locals {
  bus_arns = { for r in var.regions : r => replace(var.event_bus_arn_template, "<REGION>", r) }
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    # Confused-deputy protection: only this account's rules may use the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

data "aws_iam_policy_document" "put_events" {
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = values(local.bus_arns)
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.name}-events"
  description        = "EventBridge forwards discovery events to Zscaler's event bus"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "put_events" {
  name   = "PutEventsToZscaler"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.put_events.json
}

resource "aws_cloudwatch_event_rule" "forward" {
  for_each = local.bus_arns

  region        = each.key
  name          = var.name
  description   = "Forward discovery-relevant events to Zscaler (${each.value})"
  event_pattern = var.event_pattern
  tags          = var.tags
}

resource "aws_cloudwatch_event_target" "zscaler" {
  for_each = local.bus_arns

  region    = each.key
  rule      = aws_cloudwatch_event_rule.forward[each.key].name
  target_id = "zscaler-event-bus"
  arn       = each.value
  role_arn  = aws_iam_role.events.arn
}
