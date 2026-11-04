mock_provider "aws" {}

variables {
  name                  = "ztgw-test"
  vpc_id                = "vpc-0123456789abcdef0"
  endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
  subnet_ids = {
    "usw2-az1" = "subnet-0000000000000000a"
    "usw2-az2" = "subnet-0000000000000000b"
  }
}

run "one_endpoint_per_az" {
  command = plan

  assert {
    condition     = length(aws_vpc_endpoint.this) == 2
    error_message = "expected one endpoint per AZ"
  }
  assert {
    condition     = aws_vpc_endpoint.this["usw2-az2"].vpc_endpoint_type == "GatewayLoadBalancer"
    error_message = "endpoints must be GatewayLoadBalancer type"
  }
  assert {
    condition     = contains(aws_vpc_endpoint.this["usw2-az2"].subnet_ids, "subnet-0000000000000000b")
    error_message = "endpoint must sit in its AZ's subnet"
  }
}

run "bad_service_name" {
  command = plan
  variables {
    endpoint_service_name = "vpce-svc-123"
  }
  expect_failures = [var.endpoint_service_name]
}

run "bad_subnet_map" {
  command = plan
  variables {
    subnet_ids = { "us-west-2a" = "subnet-0000000000000000a" }
  }
  expect_failures = [var.subnet_ids]
}
