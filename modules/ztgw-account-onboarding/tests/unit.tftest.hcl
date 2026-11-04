# Unit tests for modules/ztgw-account-onboarding (mocked providers).
# Provisioners run for real in terraform test, so python = "true" makes the
# client calls no-ops; the external data sources are overridden.

mock_provider "aws" {}
mock_provider "external" {}

override_data {
  target = data.external.wds
  values = {
    result = {
      trusted_account_id = "175726779870"
      trusted_role_name  = "ZscalerTagDiscoveryRole"
      trusted_role_arn   = "arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole"
    }
  }
}

override_data {
  target = data.external.account
  values = {
    result = { exists = "true", id = "4242", external_id = "zs-ext-0001", name = "workload-111122223333" }
  }
}

override_module {
  target = module.role
  outputs = {
    role_name = "ZscalerTagDiscoveryRole"
    role_arn  = "arn:aws:iam::111122223333:role/ZscalerTagDiscoveryRole"
  }
}

variables {
  account_name      = "workload-111122223333"
  aws_account_id    = "111122223333"
  discovery_regions = ["us-west-2"]
  account_group_id  = 500
  python            = "true"
}

run "registers_and_joins_group" {
  command = apply

  assert {
    condition     = jsondecode(terraform_data.account.input.spec).aws_account_id == "111122223333" && jsondecode(terraform_data.account.input.spec).role_name == "ZscalerTagDiscoveryRole"
    error_message = "registration spec must carry the account and role"
  }
  assert {
    condition     = jsondecode(terraform_data.account.input.spec).external_id == null
    error_message = "Zscaler must generate the external ID by default"
  }
  assert {
    condition     = jsondecode(terraform_data.group_membership[0].input.spec).group_id == 500 && jsondecode(terraform_data.group_membership[0].input.spec).public_cloud_account_id == "4242"
    error_message = "group membership spec must reference the group and the new account"
  }
  assert {
    condition     = output.external_id == "zs-ext-0001" && output.trusted_role_arn == "arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole"
    error_message = "external ID and trusted role must come from Zscaler"
  }
}

run "shared_external_id_and_fixed_trusted_role" {
  command = apply
  variables {
    external_id              = "shared-ext-id-0001"
    zscaler_trusted_role_arn = "arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole"
  }
  assert {
    condition     = jsondecode(terraform_data.account.input.spec).external_id == "shared-ext-id-0001"
    error_message = "supplied external ID must be passed to registration"
  }
  assert {
    condition     = length(data.external.wds) == 0
    error_message = "tenant lookup must be skipped when the trusted role is given"
  }
}

run "no_group" {
  command = apply
  variables {
    account_group_id = null
  }
  assert {
    condition     = length(terraform_data.group_membership) == 0
    error_message = "no group membership when account_group_id is null"
  }
}

run "bad_account_id" {
  command = plan
  variables {
    aws_account_id = "1234"
  }
  expect_failures = [var.aws_account_id]
}

run "bad_region" {
  command = plan
  variables {
    discovery_regions = ["usw2"]
  }
  expect_failures = [var.discovery_regions]
}

run "bad_external_id" {
  command = plan
  variables {
    external_id = "short"
  }
  expect_failures = [var.external_id]
}
