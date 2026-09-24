# =============================================================================
# variables.tf — Bootstrap Root Module
# =============================================================================
# Every value has a default: bootstrapping the state store should be a single
# `terraform apply` with no arguments, and the account ID is read from the
# caller's own credentials rather than passed in (a wrong hardcoded account ID
# would create the bucket in someone else's account).
# =============================================================================

variable "project_name" {
  description = "Project name used for the KMS alias and resource naming"
  type        = string
  default     = "flowharbor"
}

variable "aws_region" {
  description = "Region for the state bucket. Must match the region the root module's backend block points at."
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state. S3 bucket names are global, so this usually needs the account ID appended."
  type        = string
  default     = "flowharbor-terraform-state"
}

variable "kms_key_deletion_window_in_days" {
  description = "Waiting period before the state CMK is destroyed after a destroy. Long enough to notice a mistake and re-apply."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30
    error_message = "kms_key_deletion_window_in_days must be between 7 and 30 (AWS enforces 7-30)."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent (superseded) state versions. State history is the only way back from a corrupted state file."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 30
    error_message = "noncurrent_version_expiration_days must be at least 30 — a shorter window defeats the point of versioning."
  }
}
