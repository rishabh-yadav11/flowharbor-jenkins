# =============================================================================
# Observability-Logging Module — variables.tf (issue #13)
# =============================================================================

variable "project_name" {
  description = "Project prefix for log bucket/KMS naming"
  type        = string
}
