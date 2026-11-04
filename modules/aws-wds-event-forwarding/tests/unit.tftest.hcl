# Unit tests for modules/aws-wds-event-forwarding (mocked aws provider).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  aws_account_id         = "111122223333"
  regions                = ["us-west-2", "us-east-1"]
  event_bus_arn_template = "arn:aws:events:<REGION>:175726779870:event-bus/zscaler-bus-1000-zscalertwo.net"
}

run "rule_and_target_per_region" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_event_rule.forward) == 2 && aws_cloudwatch_event_rule.forward["us-east-1"].region == "us-east-1"
    error_message = "expected one rule per region, placed in that region"
  }
  assert {
    condition     = aws_cloudwatch_event_target.zscaler["us-west-2"].arn == "arn:aws:events:us-west-2:175726779870:event-bus/zscaler-bus-1000-zscalertwo.net"
    error_message = "target must be Zscaler's bus in the same region"
  }
  assert {
    condition     = aws_cloudwatch_event_target.zscaler["us-east-1"].region == "us-east-1"
    error_message = "target must be created in the rule's region"
  }
  assert {
    condition     = contains(jsondecode(aws_cloudwatch_event_rule.forward["us-west-2"].event_pattern).source, "aws.tag")
    error_message = "provisional pattern must include tag changes"
  }
}

run "custom_pattern" {
  command = plan
  variables {
    event_pattern = "{\"source\":[\"aws.ec2\"]}"
  }
  assert {
    condition     = length(jsondecode(aws_cloudwatch_event_rule.forward["us-west-2"].event_pattern).source) == 1
    error_message = "custom pattern must be used as given"
  }
}

run "bad_template" {
  command = plan
  variables {
    event_bus_arn_template = "arn:aws:events:us-west-2:175726779870:event-bus/zscaler-bus-1"
  }
  expect_failures = [var.event_bus_arn_template]
}

run "bad_pattern" {
  command = plan
  variables {
    event_pattern = "[1,2]"
  }
  expect_failures = [var.event_pattern]
}
