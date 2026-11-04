# Mocked apply of env/example.tfvars (run by scripts/qa.sh examples with
# -var-file=env/example.tfvars). Proves the example matches the stack.

mock_provider "aws" {
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
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
    result = { exists = "true", id = "4242", external_id = "zs-ext-0001", name = "aws-111122223333" }
  }
}


variables {
  python = "true"
}

run "example_tfvars" {
  command = apply

  assert {
    condition     = length(module.onboarding) == 1
    error_message = "account must be onboarded"
  }
  assert {
    condition     = length(output.private_route_table_ids) == 3 && length(output.endpoint_ids) == 3
    error_message = "expected a route table and endpoint per default AZ"
  }
  assert {
    condition     = output.aws_account_id == "111122223333"
    error_message = "example account not used"
  }
}
