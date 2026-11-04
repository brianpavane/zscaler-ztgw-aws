# Example-tfvars validation for Phase 2 (run by scripts/qa.sh "examples"):
#
#   terraform -chdir=stacks/02-ztgw test \
#     -test-directory=tests/example -var-file=env/example.tfvars
#
# zscaler/ztc cannot skip credential validation, so the example values are
# planned and applied against mocked providers instead of real ones. This
# directory is not picked up by a plain `terraform test`.

mock_provider "ztc" {}
mock_provider "external" {}

variables {
  python = "true" # no-op: provisioners must not call the API
}

override_data {
  target = data.external.gateway
  values = {
    result = {
      exists                = "true"
      id                    = "1"
      name                  = "example"
      region                = "us-west-2"
      health_status         = "HEALTHY"
      endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
      endpoints_count       = "0"
      availability_zone_ids = "usw2-az1,usw2-az2,usw2-az3"
      location_name         = "example-loc"
      location_id           = "1"
    }
  }
}

run "example_tfvars" {
  command = apply

  assert {
    condition     = length(var.availability_zone_ids) > 0
    error_message = "example must set availability_zone_ids"
  }
}
