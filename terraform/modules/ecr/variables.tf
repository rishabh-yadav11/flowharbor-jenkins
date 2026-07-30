# =============================================================================
# ECR Module — variables.tf
# =============================================================================
# Input variables for the ECR module.
# =============================================================================

variable "project_name" {
  description = "Project name used for ECR repository naming (e.g., flowharbor-app)"
  type        = string
}
