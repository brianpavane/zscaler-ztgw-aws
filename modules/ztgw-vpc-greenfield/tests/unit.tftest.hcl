# Realistic IDs so the endpoint module's input validation accepts them.
mock_provider "aws" {
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
  }
}

variables {
  name                  = "ztgw-prod-us-west-2-wl"
  availability_zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"]
  endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
}

run "layout_per_az" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 3 && length(aws_subnet.endpoint) == 3
    error_message = "expected one private and one endpoint subnet per AZ"
  }
  assert {
    condition     = length(aws_route_table.private) == 3
    error_message = "expected one private route table per AZ"
  }
  assert {
    condition     = aws_subnet.private["usw2-az1"].cidr_block == "10.0.1.0/24" && aws_subnet.private["usw2-az3"].cidr_block == "10.0.3.0/24"
    error_message = "private subnets must be blocks 1..n"
  }
  assert {
    condition     = aws_subnet.endpoint["usw2-az1"].cidr_block == "10.0.0.0/28" && aws_subnet.endpoint["usw2-az2"].cidr_block == "10.0.0.16/28"
    error_message = "endpoint subnets must be /28s inside block 0"
  }
  assert {
    condition     = aws_subnet.private["usw2-az2"].availability_zone_id == "usw2-az2"
    error_message = "subnets must be placed by AZ ID"
  }
  assert {
    condition     = alltrue([for r in aws_route.default_via_ztgw : r.destination_cidr_block == "0.0.0.0/0"])
    error_message = "every private route table needs a default route"
  }
}

run "routes_use_same_az_endpoint" {
  command = apply

  assert {
    condition     = alltrue([for az, r in aws_route.default_via_ztgw : r.vpc_endpoint_id == module.endpoints.endpoint_ids[az]])
    error_message = "each private default route must target its own AZ's endpoint"
  }
  assert {
    condition     = alltrue([for az, r in aws_route.default_via_ztgw : r.route_table_id == aws_route_table.private[az].id])
    error_message = "routes must be in the per-AZ route tables"
  }
}

run "small_vpc" {
  command = plan
  variables {
    vpc_cidr               = "172.16.0.0/22"
    private_subnet_newbits = 2
    availability_zone_ids  = ["usw2-az1", "usw2-az2"]
  }
  assert {
    condition     = aws_subnet.private["usw2-az2"].cidr_block == "172.16.2.0/24" && aws_subnet.endpoint["usw2-az2"].cidr_block == "172.16.0.16/28"
    error_message = "unexpected addressing for a /22"
  }
}

run "too_many_azs_for_vpc" {
  command = plan
  variables {
    vpc_cidr               = "172.16.0.0/22"
    private_subnet_newbits = 2
    availability_zone_ids  = ["usw2-az1", "usw2-az2", "usw2-az3", "usw2-az4"]
  }
  expect_failures = [aws_vpc.this]
}

run "bad_cidr" {
  command = plan
  variables {
    vpc_cidr = "10.0.0.0/8"
  }
  expect_failures = [var.vpc_cidr]
}

run "duplicate_azs" {
  command = plan
  variables {
    availability_zone_ids = ["usw2-az1", "usw2-az1"]
  }
  expect_failures = [var.availability_zone_ids]
}
