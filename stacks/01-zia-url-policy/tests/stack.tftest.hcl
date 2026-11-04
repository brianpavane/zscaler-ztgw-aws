# Stack-level tests for Phase 1 (mocked zia provider; no tenant needed).
# Run with: terraform -chdir=stacks/01-zia-url-policy test
#
# Note: the location_names path cannot be unit tested -- the zia provider marks
# zia_location_management.id as optional (not computed), so mocks/overrides
# leave it null. It is covered by the live integration run (docs/qa.md).

mock_provider "zia" {
  mock_resource "zia_url_categories" {
    defaults = {
      id = "CUSTOM_02"
    }
  }
  mock_resource "zia_url_filtering_rules" {
    defaults = {
      rule_id = 2002
    }
  }
}

variables {
  name_prefix    = "ztgw-stack-test"
  allowed_urls   = [".github.com"]
  blocked_urls   = [".bad.example"]
  default_action = "BLOCK"
}

run "staged_without_location" {
  command = apply

  expect_failures = [check.policy_is_scoped]

  assert {
    condition     = output.rule_state == "DISABLED"
    error_message = "policy must be staged (DISABLED) with no location"
  }
  assert {
    condition     = length(zia_activation_status.this) == 1
    error_message = "activation must run by default"
  }
}

run "attached_to_gateway_location" {
  command = apply

  variables {
    location_ids = [98765]
  }

  assert {
    condition     = output.rule_state == "ENABLED"
    error_message = "policy must be ENABLED once a location is supplied"
  }
  assert {
    condition     = length(output.location_ids) == 1 && output.location_ids[0] == 98765
    error_message = "policy must be scoped to the supplied location ID"
  }
  assert {
    condition     = output.rule_orders == { allow = 1, block = 2, default = 3 }
    error_message = "rule orders must be 1,2,3"
  }
}

run "activation_can_be_disabled" {
  command = plan

  variables {
    activate = false
  }

  expect_failures = [check.policy_is_scoped]

  assert {
    condition     = length(zia_activation_status.this) == 0
    error_message = "activate = false must skip activation"
  }
}
