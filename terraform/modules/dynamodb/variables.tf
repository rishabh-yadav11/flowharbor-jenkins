# =============================================================================
# DynamoDB Module — variables.tf
# Input variables for the application data layer.
# =============================================================================

variable "project_name" {
  description = "Project name used for the table name and tagging"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the project KMS CMK used to encrypt the table (wired from the observability_logging module)"
  type        = string
}
