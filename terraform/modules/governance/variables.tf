# =============================================================================
# Governance Module — variables.tf
# Input variables for AWS Config and Security Hub.
# =============================================================================

variable "project_name" {
  description = "Project name used for Config/Security Hub resource naming and tagging"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the project KMS CMK used to encrypt the Config snapshot bucket (wired from the observability_logging module)"
  type        = string
}
