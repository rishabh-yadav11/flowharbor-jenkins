# =============================================================================
# versions.tf — Bootstrap Root Module
# =============================================================================
# This module is a SEPARATE root module, not a child of terraform/. It creates
# the remote state store, which must exist before the root module can be
# initialized against it — so it cannot be part of the configuration it stores.
#
# It deliberately has NO backend block: it uses local state, and that local
# state describes one bucket and one key. Losing it costs a re-create; losing
# the root module's state costs the whole stack.
#
# The provider constraint matches the root module exactly, so the two never
# disagree about resource schema.
# =============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}
