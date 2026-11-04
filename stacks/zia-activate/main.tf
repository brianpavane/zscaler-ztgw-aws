# -----------------------------------------------------------------------------
# Utility stack: activate pending ZIA changes for the whole tenant.
#
# zia_activation_status only fires on create, so scripts/run.sh applies this
# stack with -replace to force a fresh activation, e.g. after destroying a
# policy stack (Terraform cannot activate deletions from inside the stack
# being destroyed).
#
#   scripts/run.sh <env> zia-activate apply
# -----------------------------------------------------------------------------

resource "zia_activation_status" "this" {
  status = "ACTIVE"
}
