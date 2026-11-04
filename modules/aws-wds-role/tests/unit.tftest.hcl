# Unit tests for modules/aws-wds-role (mocked aws provider).
# The policy documents are rendered by the real data source logic in the
# mock, so the assertions check the JSON that would be sent to IAM.

mock_provider "aws" {
  override_data {
    target = data.aws_iam_policy_document.trust
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"AWS\":\"arn:aws:iam::644370868001:role/ZscalerTagDiscoveryRole\"},\"Condition\":{\"StringEquals\":{\"sts:ExternalId\":\"ext-123\"}}}]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.tag_discovery
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ec2:DescribeVpcs\"],\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  role_name        = "zscaler-discovery"
  trusted_role_arn = "arn:aws:iam::644370868001:role/ZscalerTagDiscoveryRole"
  external_id      = "ext-123"
}

run "role_matches_template" {
  command = plan

  assert {
    condition     = aws_iam_role.discovery.name == "zscaler-discovery"
    error_message = "role name must be the TrustingAccountRoleName"
  }
  assert {
    condition     = aws_iam_role_policy.tag_discovery.name == "TagDiscovery"
    error_message = "inline policy must be named TagDiscovery as in the template"
  }
  assert {
    condition     = jsondecode(aws_iam_role.discovery.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "ext-123"
    error_message = "trust policy must require the external ID"
  }
}

run "bad_role_name" {
  command = plan
  variables {
    role_name = "has spaces"
  }
  expect_failures = [var.role_name]
}

run "bad_trusted_arn" {
  command = plan
  variables {
    trusted_role_arn = "644370868001"
  }
  expect_failures = [var.trusted_role_arn]
}

run "bad_external_id" {
  command = plan
  variables {
    external_id = "has space"
  }
  expect_failures = [var.external_id]
}
