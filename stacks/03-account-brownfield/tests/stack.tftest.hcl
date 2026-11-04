# Stack tests for 03-account-brownfield (mocked providers).
# Two AZs; each private route table serves one subnet in its own AZ and has
# an existing default route to an internet/NAT gateway.

mock_provider "aws" {
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-0e0e0e0e0e0e0e0e0" }
  }
  # EC2 leaves network_interface_id empty for gateway/endpoint routes; a
  # random mock value would look like a second route target.
  mock_resource "aws_route" {
    defaults = { network_interface_id = "", instance_id = "", instance_owner_id = "" }
  }
  mock_resource "aws_vpc_endpoint" {
    defaults = { id = "vpce-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16", cidr_block_associations = [] }
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
  values = { result = { trusted_account_id = "175726779870", trusted_role_name = "ZscalerTagDiscoveryRole", trusted_role_arn = "arn:aws:iam::175726779870:role/ZscalerTagDiscoveryRole" } }
}
override_data {
  target = module.onboarding[0].data.external.account
  values = { result = { exists = "true", id = "4242", external_id = "zs-ext-0001", name = "aws-111122223333", event_bus_name = "arn:aws:events:<REGION>:175726779870:event-bus/zscaler-bus-1000-zscalertwo.net" } }
}
override_data {
  target = data.aws_route_table.private["usw2-az1"]
  values = { vpc_id = "vpc-0a1b2c3d4e5f60718", associations = [{ subnet_id = "subnet-00000000000000a01", main = false, gateway_id = "", route_table_association_id = "rtbassoc-1", route_table_id = "rtb-0a1b2c3d4e5f60711" }] }
}
override_data {
  target = data.aws_route_table.private["usw2-az2"]
  values = { vpc_id = "vpc-0a1b2c3d4e5f60718", associations = [{ subnet_id = "subnet-00000000000000a02", main = false, gateway_id = "", route_table_association_id = "rtbassoc-2", route_table_id = "rtb-0a1b2c3d4e5f60712" }] }
}
override_data {
  target = data.aws_subnet.associated["subnet-00000000000000a01"]
  values = { availability_zone_id = "usw2-az1", vpc_id = "vpc-0a1b2c3d4e5f60718" }
}
override_data {
  target = data.aws_subnet.associated["subnet-00000000000000a02"]
  values = { availability_zone_id = "usw2-az2", vpc_id = "vpc-0a1b2c3d4e5f60718" }
}
override_data {
  target = data.aws_route.current["usw2-az1"]
  values = { gateway_id = "igw-0123456789abcdef0", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "", vpc_peering_connection_id = "", carrier_gateway_id = "", local_gateway_id = "", core_network_arn = "", instance_id = "", egress_only_gateway_id = "" }
}
override_data {
  target = data.aws_route.current["usw2-az2"]
  values = { gateway_id = "", nat_gateway_id = "nat-0123456789abcdef0", transit_gateway_id = "", network_interface_id = "", vpc_peering_connection_id = "", carrier_gateway_id = "", local_gateway_id = "", core_network_arn = "", instance_id = "", egress_only_gateway_id = "" }
}

variables {
  # Mock providers cannot import; the import blocks are covered by the live
  # runbook. Here the routes are planned as new resources instead.
  import_existing_routes = false

  python                = "true"
  aws_account_id        = "111122223333"
  ztgw_account_group_id = 500
  endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
  availability_zone_ids = ["usw2-az1", "usw2-az2"]
  vpc_id                = "vpc-0a1b2c3d4e5f60718"
  route_table_ids = {
    "usw2-az1" = "rtb-0a1b2c3d4e5f60711"
    "usw2-az2" = "rtb-0a1b2c3d4e5f60712"
  }
  endpoint_subnet_cidrs = {
    "usw2-az1" = "10.0.255.0/28"
    "usw2-az2" = "10.0.255.16/28"
  }
}

run "cutover" {
  command = apply

  assert {
    condition     = alltrue([for az, r in aws_route.default : r.vpc_endpoint_id == module.endpoints.endpoint_ids[az] && r.gateway_id == null && r.nat_gateway_id == null])
    error_message = "cutover must point every default route at its AZ's endpoint only"
  }
  assert {
    condition     = terraform_data.original_route["usw2-az1"].output.gateway_id == "igw-0123456789abcdef0" && terraform_data.original_route["usw2-az2"].output.nat_gateway_id == "nat-0123456789abcdef0"
    error_message = "original targets must be recorded"
  }
  assert {
    condition     = length(aws_subnet.endpoint) == 2 && length(aws_route_table.endpoint) == 1
    error_message = "endpoint subnets and their dedicated route table must be created"
  }
}

run "rollback" {
  command = apply
  variables {
    cutover = false
  }
  assert {
    condition     = aws_route.default["usw2-az1"].gateway_id == "igw-0123456789abcdef0" && aws_route.default["usw2-az1"].vpc_endpoint_id == null
    error_message = "rollback must restore the internet gateway route"
  }
  assert {
    condition     = aws_route.default["usw2-az2"].nat_gateway_id == "nat-0123456789abcdef0" && aws_route.default["usw2-az2"].gateway_id == null
    error_message = "rollback must restore the NAT gateway route"
  }
}

run "release_routes" {
  command = plan
  variables {
    release_routes = true
  }
  assert {
    condition     = length(aws_route.default) == 0
    error_message = "release_routes must stop managing the routes"
  }
}

run "route_table_keys_must_match_azs" {
  command = plan
  variables {
    availability_zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"]
  }
  expect_failures = [terraform_data.layout_checks]
}

run "both_endpoint_subnet_inputs" {
  command = plan
  variables {
    endpoint_subnet_ids = {
      "usw2-az1" = "subnet-00000000000000b01"
      "usw2-az2" = "subnet-00000000000000b02"
    }
  }
  expect_failures = [terraform_data.layout_checks]
}

run "endpoint_cidr_outside_vpc" {
  command = plan
  variables {
    endpoint_subnet_cidrs = {
      "usw2-az1" = "192.168.0.0/28"
      "usw2-az2" = "10.0.255.16/28"
    }
  }
  expect_failures = [terraform_data.layout_checks]
}

run "endpoint_cidr_not_network_address" {
  command = plan
  variables {
    endpoint_subnet_cidrs = {
      "usw2-az1" = "10.0.255.5/28"
      "usw2-az2" = "10.0.255.16/28"
    }
  }
  expect_failures = [terraform_data.layout_checks]
}

run "route_table_serves_other_az" {
  command = plan
  override_data {
    target = data.aws_subnet.associated["subnet-00000000000000a02"]
    values = { availability_zone_id = "usw2-az1", vpc_id = "vpc-0a1b2c3d4e5f60718" }
  }
  expect_failures = [terraform_data.layout_checks]
}

run "main_route_table_rejected" {
  command = plan
  override_data {
    target = data.aws_route_table.private["usw2-az1"]
    values = { vpc_id = "vpc-0a1b2c3d4e5f60718", associations = [{ subnet_id = "subnet-00000000000000a01", main = true, gateway_id = "", route_table_association_id = "rtbassoc-1", route_table_id = "rtb-0a1b2c3d4e5f60711" }] }
  }
  expect_failures = [terraform_data.layout_checks]
}

run "route_table_in_other_vpc" {
  command = plan
  override_data {
    target = data.aws_route_table.private["usw2-az2"]
    values = { vpc_id = "vpc-0ffffffffffffffff", associations = [{ subnet_id = "subnet-00000000000000a02", main = false, gateway_id = "", route_table_association_id = "rtbassoc-2", route_table_id = "rtb-0a1b2c3d4e5f60712" }] }
  }
  expect_failures = [terraform_data.layout_checks]
}

run "duplicate_route_tables" {
  command = plan
  variables {
    route_table_ids = {
      "usw2-az1" = "rtb-0a1b2c3d4e5f60711"
      "usw2-az2" = "rtb-0a1b2c3d4e5f60711"
    }
  }
  expect_failures = [var.route_table_ids]
}

run "route_already_on_unknown_endpoint" {
  # A default route found pointing at an endpoint that is not ours (e.g.
  # state was lost): the original target is unknown, so stop. Runs after
  # the earlier runs, so our endpoint IDs are known at plan time.
  command = plan
  variables {
    cutover = true
  }
  override_data {
    target = data.aws_route.current["usw2-az1"]
    values = { gateway_id = "vpce-0999999999999999f", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "", vpc_peering_connection_id = "", carrier_gateway_id = "", local_gateway_id = "", core_network_arn = "", instance_id = "", egress_only_gateway_id = "" }
  }
  expect_failures = [terraform_data.original_route]
}
