# =============================================================================
# IAM Module — variables.tf
# =============================================================================
# Input variables for the IAM module.
# =============================================================================

variable "project_name" {
  description = "Project name used for IAM role naming and tagging"
  type        = string
}

variable "alerts_topic_arn" {
  description = "ARN of the KMS-encrypted SNS alert topic — the ONLY topic the Jenkins slave may publish to"
  type        = string
}

variable "todo_table_arn" {
  description = "ARN of the todos DynamoDB table — scopes the ECS task role's data-layer permissions"
  type        = string
}
