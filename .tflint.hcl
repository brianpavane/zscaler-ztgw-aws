# tflint configuration - used by scripts/qa.sh, pre-commit and CI.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

# The AWS ruleset is enabled from Phase 2 onward (aws provider stacks).
plugin "aws" {
  enabled = true
  version = "0.36.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
