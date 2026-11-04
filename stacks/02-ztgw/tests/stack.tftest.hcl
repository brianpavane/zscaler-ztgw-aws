# Stack-level tests for Phase 2 (mocked ztc/external providers; no tenant).
# Run with: terraform -chdir=stacks/02-ztgw test
#
# terraform_data provisioners are real local-exec commands even with mocked
# providers, so `python` is set to the no-op `true` command: create/update/
# delete/activate provisioners run `true ...` and succeed without calling the
# API, and the gateway read-back comes from override_data. The client itself
# is covered by tests/python.

mock_provider "ztc" {}
mock_provider "external" {}

variables {
  python = "true"
}

# What scripts/ztgw/ztgw.py `read` returns for a healthy gateway.
override_data {
  target = data.external.gateway
  values = {
    result = {
      exists                = "true"
      id                    = "1000"
      name                  = "ztgw-default-us-west-2"
      region                = "us-west-2"
      health_status         = "HEALTHY"
      endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
      endpoints_count       = "0"
      availability_zone_ids = "usw2-az1,usw2-az2,usw2-az3"
      location_name         = "ztgw-default-us-west-2-loc"
      location_id           = "9000"
    }
  }
}

run "defaults" {
  command = apply

  assert {
    condition     = output.gateway_name == "ztgw-default-us-west-2"
    error_message = "default gateway name must be ztgw-<workspace>-<region>"
  }
  assert {
    condition     = output.location_name == "ztgw-default-us-west-2-loc"
    error_message = "default location name must be <gateway_name>-loc"
  }
  assert {
    condition     = terraform_data.gateway.input.region == "us-west-2"
    error_message = "default region must be us-west-2"
  }
  assert {
    condition     = length(terraform_data.gateway.input.availability_zone_ids) == 3 && terraform_data.gateway.input.availability_zone_ids[2] == "usw2-az3"
    error_message = "default AZs must be usw2-az1..3"
  }
  assert {
    condition     = terraform_data.gateway.input.cleanup_location == true
    error_message = "location cleanup must default to true"
  }
  assert {
    condition     = length(ztc_location_template.this) == 1 && ztc_location_template.this[0].name == "ztgw-default-us-west-2-tmpl"
    error_message = "a location template must be created by default"
  }
  assert {
    condition     = length(ztc_account_groups.consumers) == 1 && ztc_account_groups.consumers[0].name == "ztgw-default-us-west-2-consumers"
    error_message = "a consumer account group must be created by default"
  }
  assert {
    condition     = ztc_account_groups.consumers[0].cloud_type == "AWS"
    error_message = "account group must be AWS"
  }
  assert {
    condition     = strcontains(terraform_data.gateway.input.python_cmd, "true -I") && strcontains(terraform_data.gateway.input.python_cmd, "scripts/ztgw/ztgw.py")
    error_message = "destroy command must call the client"
  }
  assert {
    condition     = startswith(output.endpoint_service_name, "com.amazonaws.vpce.") && output.location_id == "9000"
    error_message = "endpoint service name and location id must come from the gateway read"
  }
}

run "custom_region_names_and_azs" {
  command = apply

  variables {
    region                = "us-east-1"
    availability_zone_ids = ["use1-az1", "use1-az4"]
    gateway_name          = "ztgw-prod-east"
    location_name         = "ztgw-prod-east-location"
  }

  assert {
    condition     = terraform_data.gateway.input.name == "ztgw-prod-east" && terraform_data.gateway.input.location_name == "ztgw-prod-east-location"
    error_message = "custom names must be used"
  }
  assert {
    condition     = terraform_data.gateway.triggers_replace.region == "us-east-1" && length(terraform_data.gateway.triggers_replace.availability_zone_ids) == 2
    error_message = "region and AZs must be replace triggers"
  }
}

run "existing_template_and_no_group" {
  command = apply

  variables {
    existing_location_template_name = "corp-template"
    create_account_group            = false
    additional_aws_accounts         = ["123456789012"]
  }

  override_data {
    target = data.ztc_location_template.existing
    values = {
      id = 55
    }
  }

  assert {
    condition     = length(ztc_location_template.this) == 0
    error_message = "no template must be created when an existing one is named"
  }
  assert {
    condition     = terraform_data.gateway.input.location_template_id == 55
    error_message = "existing template id must be used"
  }
  assert {
    condition     = length(ztc_account_groups.consumers) == 0 && length(terraform_data.gateway.input.account_group_ids) == 0
    error_message = "no account group expected"
  }
  assert {
    condition     = terraform_data.gateway_settings.triggers_replace.additional_aws_accounts[0] == "123456789012"
    error_message = "additional AWS accounts must be a mutable (update) setting"
  }
}

run "group_members_and_extra_groups" {
  command = apply

  variables {
    account_group_member_ids = [7001, 7002]
    account_group_ids        = [42]
  }

  assert {
    condition     = one(ztc_account_groups.consumers[0].public_cloud_accounts).id == toset([7001, 7002])
    error_message = "members must be placed in the consumer group"
  }
  assert {
    condition     = length(terraform_data.gateway.input.account_group_ids) == 2
    error_message = "gateway must allow the consumer group and the extra group"
  }
}

run "nobody_allowed_warns" {
  command = apply

  variables {
    create_account_group = false
  }

  expect_failures = [check.consumers_allowed]
}

run "az_names_rejected" {
  command = plan

  variables {
    availability_zone_ids = ["us-west-2a", "us-west-2b"]
  }

  expect_failures = [var.availability_zone_ids]
}

run "duplicate_azs_rejected" {
  command = plan

  variables {
    availability_zone_ids = ["usw2-az1", "usw2-az1"]
  }

  expect_failures = [var.availability_zone_ids]
}

run "bad_region_rejected" {
  command = plan

  variables {
    region = "US_WEST_2"
  }

  expect_failures = [var.region]
}

run "bad_account_rejected" {
  command = plan

  variables {
    additional_aws_accounts = ["1234-5678"]
  }

  expect_failures = [var.additional_aws_accounts]
}

run "bad_gateway_name_rejected" {
  command = plan

  variables {
    gateway_name = "bad name; rm -rf"
  }

  expect_failures = [var.gateway_name]
}

run "timeout_bounds" {
  command = plan

  variables {
    health_timeout_seconds = 10
  }

  expect_failures = [var.health_timeout_seconds]
}

run "unhealthy_gateway_is_reported" {
  command = apply

  override_data {
    target = data.external.gateway
    values = {
      result = {
        exists                = "true"
        id                    = "1000"
        name                  = "ztgw-default-us-west-2"
        region                = "us-west-2"
        health_status         = "UNHEALTHY"
        endpoint_service_name = ""
        endpoints_count       = "0"
        availability_zone_ids = "usw2-az1,usw2-az2,usw2-az3"
        location_name         = "ztgw-default-us-west-2-loc"
        location_id           = "9000"
      }
    }
  }

  expect_failures = [check.gateway_ready]
}
