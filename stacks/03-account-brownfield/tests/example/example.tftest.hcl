# Mocked apply of env/example.tfvars (run by scripts/qa.sh examples with
# -var-file=env/example.tfvars). Proves the example matches the stack.
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
  values = { result = { exists = "true", id = "4242", external_id = "zs-ext-0001", name = "aws-111122223333" } }
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


override_data {
  target = data.aws_route_table.private["usw2-az3"]
  values = { vpc_id = "vpc-0a1b2c3d4e5f60718", associations = [{ subnet_id = "subnet-00000000000000a03", main = false, gateway_id = "", route_table_association_id = "rtbassoc-3", route_table_id = "rtb-0a1b2c3d4e5f60713" }] }
}
override_data {
  target = data.aws_subnet.associated["subnet-00000000000000a03"]
  values = { availability_zone_id = "usw2-az3", vpc_id = "vpc-0a1b2c3d4e5f60718" }
}
override_data {
  target = data.aws_route.current["usw2-az3"]
  values = { gateway_id = "igw-0123456789abcdef0", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "", vpc_peering_connection_id = "", carrier_gateway_id = "", local_gateway_id = "", core_network_arn = "", instance_id = "", egress_only_gateway_id = "" }
}

variables {
  python                 = "true"
  import_existing_routes = false
}

run "example_tfvars" {
  command = apply

  assert {
    condition     = length(aws_route.default) == 3 && length(module.endpoints.endpoint_ids) == 3
    error_message = "example must manage one default route and endpoint per AZ"
  }
}
