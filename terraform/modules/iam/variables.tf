# =============================================================================
# IAM Module — variables.tf
# =============================================================================
# Input variables for the IAM module.
# =============================================================================

variable "project_name" {
  description = "Project name used for IAM role naming and tagging"
  type        = string
}
