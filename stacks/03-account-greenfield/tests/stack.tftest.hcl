# Stack tests for 03-account-greenfield (mocked providers).
# Provisioners run for real, so python = "true" makes them no-ops; the
# wds-settings external data source is overridden.

mock_provider "aws" {
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "ztc" {
  mock_data "ztc_account_groups" {
    defaults = { id = 500 }
  }
}
mock_provider "external" {}

override_data {
  target = module.onboarding[0].data.external.wds
  values = {
    result = {
      trusted_account_id = "175726779870"
      trusted_role_name  = "ZscalerTagDiscoveryRole"
      trusted_role_arn   = "arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole"
    }
  }
}

override_data {
  target = module.onboarding[0].data.external.account
  values = {
    result = { exists = "true", id = "4242", external_id = "zs-ext-0001", name = "aws-111122223333", event_bus_name = "arn:aws:events:<REGION>:175726779870:event-bus/zscaler-bus-1000-zscalertwo.net" }
  }
}

variables {
  python                = "true"
  aws_account_id        = "111122223333"
  ztgw_account_group_id = 500
  endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
}

run "onboards_and_builds_vpc" {
  command = apply

  assert {
    condition     = length(module.onboarding) == 1 && output.public_cloud_account_id == "4242"
    error_message = "account must be onboarded"
  }
  assert {
    condition     = length(output.private_route_table_ids) == 3 && length(output.endpoint_ids) == 3
    error_message = "expected a route table and endpoint per default AZ"
  }
  assert {
    condition     = local.name == "ztgw-default-us-west-2-wl" && local.account_name == "aws-111122223333"
    error_message = "default naming convention not applied"
  }
}

run "wds_disabled" {
  command = apply
  variables {
    enable_wds = false
  }
  assert {
    condition     = length(module.onboarding) == 0
    error_message = "no onboarding when enable_wds = false"
  }
}

run "event_forwarding_enabled" {
  command = apply
  variables {
    enable_event_forwarding = true
  }
  assert {
    condition     = length(output.event_forwarding_rule_arns) == 1
    error_message = "one forwarding rule expected for the default discovery region"
  }
}

run "no_group_warns" {
  command = apply
  variables {
    ztgw_account_group_id = null
  }
  expect_failures = [check.gateway_access]
}

run "endpoint_service_other_region" {
  command = apply
  variables {
    endpoint_service_name = "com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0"
  }
  expect_failures = [check.endpoint_service_region]
}

run "assume_role_mode_accepted" {
  command = apply
  variables {
    aws_assume_role_arn         = "arn:aws:iam::111122223333:role/ZscalerAutomation"
    aws_assume_role_external_id = "abc"
  }
}

run "bad_assume_role_arn" {
  command = plan
  variables {
    aws_assume_role_arn = "ZscalerAutomation"
  }
  expect_failures = [var.aws_assume_role_arn]
}

run "bad_account_id" {
  command = plan
  variables {
    aws_account_id = "11112222333"
  }
  expect_failures = [var.aws_account_id]
}
