# Unit tests for modules/zia-url-policy.
# Run with: terraform -chdir=modules/zia-url-policy test
# The zia provider is mocked, so no tenant or credentials are needed.

mock_provider "zia" {
  mock_resource "zia_url_categories" {
    defaults = {
      id = "CUSTOM_01"
    }
  }
  mock_resource "zia_url_filtering_rules" {
    defaults = {
      rule_id = 1001
    }
  }
}

variables {
  name_prefix  = "ztgw-test"
  location_ids = [12345]
}

run "default_allow_creates_no_catch_all" {
  command = plan

  variables {
    allowed_urls   = [".example.com"]
    blocked_urls   = ["bad.example.net"]
    default_action = "ALLOW"
  }

  assert {
    condition     = length(zia_url_filtering_rules.default) == 0
    error_message = "default_action = ALLOW must not create a catch-all rule"
  }
  assert {
    condition     = zia_url_filtering_rules.allow[0].order == 1 && zia_url_filtering_rules.block[0].order == 2
    error_message = "allow/block rules must occupy orders 1 and 2"
  }
  assert {
    condition     = zia_url_filtering_rules.allow[0].action == "ALLOW" && zia_url_filtering_rules.block[0].action == "BLOCK"
    error_message = "rule actions are wrong"
  }
}

run "default_block_adds_catch_all_last" {
  command = plan

  variables {
    allowed_urls   = [".example.com"]
    blocked_urls   = ["bad.example.net"]
    default_action = "BLOCK"
  }

  assert {
    condition     = zia_url_filtering_rules.default[0].order == 3
    error_message = "catch-all must be the last rule (order 3)"
  }
  assert {
    condition     = zia_url_filtering_rules.default[0].action == "BLOCK"
    error_message = "catch-all must BLOCK"
  }
  assert {
    condition     = length(zia_url_filtering_rules.default[0].url_categories) == 1 && contains(zia_url_filtering_rules.default[0].url_categories, "ANY")
    error_message = "catch-all must match url_categories = ANY"
  }
}

run "allow_only_default_block_orders_contiguous" {
  command = plan

  variables {
    allowed_urls     = [".example.com", "docs.example.org"]
    default_action   = "BLOCK"
    rule_order_start = 5
  }

  assert {
    condition     = length(zia_url_filtering_rules.block) == 0 && length(zia_url_categories.block) == 0
    error_message = "no block rule/category expected when blocked_urls is empty"
  }
  assert {
    condition     = zia_url_filtering_rules.allow[0].order == 5 && zia_url_filtering_rules.default[0].order == 6
    error_message = "orders must be contiguous starting at rule_order_start"
  }
  assert {
    condition     = output.rule_orders == { allow = 5, default = 6 }
    error_message = "rule_orders output is wrong"
  }
}

run "block_only_default_allow" {
  command = plan

  variables {
    blocked_urls = [".gambling.example"]
  }

  assert {
    condition     = length(zia_url_filtering_rules.allow) == 0 && length(zia_url_filtering_rules.default) == 0
    error_message = "only the block rule should exist"
  }
  assert {
    condition     = zia_url_filtering_rules.block[0].order == 1
    error_message = "block rule must take order 1 when it is the only rule"
  }
}

run "urls_are_normalised" {
  command = plan

  variables {
    allowed_urls = ["  .Example.COM "]
  }

  assert {
    condition     = length(zia_url_categories.allow[0].urls) == 1 && zia_url_categories.allow[0].urls[0] == ".example.com"
    error_message = "URLs must be trimmed and lower-cased"
  }
  assert {
    condition     = zia_url_categories.allow[0].super_category == "USER_DEFINED" && zia_url_categories.allow[0].custom_category
    error_message = "category must be a USER_DEFINED custom category"
  }
}

run "rules_scoped_to_locations_and_enabled" {
  command = plan

  variables {
    allowed_urls = [".example.com"]
    location_ids = [111, 222]
  }

  assert {
    condition     = zia_url_filtering_rules.allow[0].state == "ENABLED"
    error_message = "rules must be ENABLED when scoped"
  }
  assert {
    condition     = one(zia_url_filtering_rules.allow[0].locations).id == toset([111, 222])
    error_message = "rule must be scoped to the supplied locations"
  }
}

run "unscoped_rules_are_disabled" {
  command = plan

  variables {
    allowed_urls   = [".example.com"]
    default_action = "BLOCK"
    location_ids   = []
  }

  assert {
    condition     = zia_url_filtering_rules.allow[0].state == "DISABLED" && zia_url_filtering_rules.default[0].state == "DISABLED"
    error_message = "rules without locations would apply tenant-wide and must be DISABLED"
  }
  assert {
    condition     = length(zia_url_filtering_rules.default[0].locations) == 0
    error_message = "no locations block expected"
  }
}

run "path_entries_warn" {
  command = plan

  variables {
    blocked_urls = ["example.com/login"]
  }

  expect_failures = [check.path_entries_need_ssl_inspection]
}

run "overlap_is_rejected" {
  command = plan

  variables {
    allowed_urls = [".example.com"]
    blocked_urls = [".EXAMPLE.com"]
  }

  expect_failures = [zia_url_categories.allow, zia_url_categories.block]
}

run "scheme_is_rejected" {
  command = plan

  variables {
    allowed_urls = ["https://example.com"]
  }

  expect_failures = [var.allowed_urls]
}

run "wildcard_is_rejected" {
  command = plan

  variables {
    blocked_urls = ["*.example.com"]
  }

  expect_failures = [var.blocked_urls]
}

run "duplicates_are_rejected" {
  command = plan

  variables {
    allowed_urls = ["example.com", "EXAMPLE.com"]
  }

  expect_failures = [var.allowed_urls]
}

run "bad_default_action_rejected" {
  command = plan

  variables {
    default_action = "DENY"
  }

  expect_failures = [var.default_action]
}

run "bad_rule_order_rejected" {
  command = plan

  variables {
    rule_order_start = 0
  }

  expect_failures = [var.rule_order_start]
}

run "no_urls_default_block_only" {
  command = plan

  variables {
    default_action = "BLOCK"
  }

  assert {
    condition     = length(zia_url_categories.allow) == 0 && length(zia_url_categories.block) == 0
    error_message = "no categories expected"
  }
  assert {
    condition     = zia_url_filtering_rules.default[0].order == 1
    error_message = "catch-all alone must take order 1"
  }
}
