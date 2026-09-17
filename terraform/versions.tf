# =============================================================================
# versions.tf — Terraform & Provider Version Constraints
# =============================================================================
# Pinning versions makes builds reproducible and avoids surprise upgrades that
# could change resource behavior or introduce regressions. Keeping the provider
# within the 5.x major series guarantees compatibility with existing state.
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