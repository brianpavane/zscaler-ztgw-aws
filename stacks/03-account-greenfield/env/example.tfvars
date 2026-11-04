# Copy to env/<env>.tfvars (git-ignored). Values from Phase 2:
#   scripts/run.sh <env> 02-ztgw output
region         = "us-west-2"
aws_account_id = "111122223333"

# Assume-role mode (omit both for direct mode):
# aws_assume_role_arn         = "arn:aws:iam::111122223333:role/ZscalerAutomation"
# aws_assume_role_external_id = "my-external-id"

ztgw_account_group_id = 12345
endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
availability_zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"]

vpc_cidr               = "10.20.0.0/16"
private_subnet_newbits = 8
