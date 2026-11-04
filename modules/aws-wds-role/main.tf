# -----------------------------------------------------------------------------
# Zscaler Workload Discovery (tag discovery) role.
#
# Native Terraform equivalent of Zscaler's CloudFormation template
# "Zscaler Tag discovery service for VPC, Subnet, EC2 and ENI version 1.0.1"
# (zscaler_discovery_role.yaml, downloaded from the Cloud & Branch Connector
# portal). Keep it identical to that template when Zscaler revises it:
#   - trust: Zscaler's discovery role, only with the matching sts:ExternalId
#   - inline policy "TagDiscovery": read-only EC2 Describe* actions
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.trusted_role_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

data "aws_iam_policy_document" "tag_discovery" {
  # Describe* calls do not support resource-level permissions, so "*" is
  # required (and is what the Zscaler template uses).
  #checkov:skip=CKV_AWS_356:Describe* actions cannot be scoped to resources
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      # optional in the Zscaler template, included there by default
      "ec2:DescribeIamInstanceProfileAssociations",
      "ec2:DescribeVpcEndpoints",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "discovery" {
  name               = var.role_name
  description        = "Role to provide access to read custom tags and attribute"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "tag_discovery" {
  name   = "TagDiscovery"
  role   = aws_iam_role.discovery.id
  policy = data.aws_iam_policy_document.tag_discovery.json
}
