# =============================================================================
# Jenkins Master Module — variables.tf
# =============================================================================
# Input variables for the Jenkins Master module.
# =============================================================================

variable "project_name" {
  description = "Project name used for instance naming and SSM parameter paths"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID for the Jenkins Master instance (should be in the first AZ)"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the Jenkins Master instance (allows 8080 from ALB + slave, 50000 from slave)"
  type        = string
}

variable "iam_instance_profile" {
  description = "IAM instance profile name for the Master (SSM management, ECR read-only)"
  type        = string
}

variable "domain_name" {
  description = "Root domain name passed to the bootstrap script for DNS-based configuration"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL passed to the bootstrap script for credential creation"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/name form — rendered into the Job DSL so the pipeline jobs clone the right remote instead of a hardcoded one"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be in owner/name form (e.g. rishabh-yadav11/flowharbor-jenkins)."
  }
}

variable "alerts_topic_arn" {
  description = "ARN of the KMS-encrypted SNS alert topic, created as the Jenkins alerts-topic-arn string credential and rendered into the bootstrap script"
  type        = string
}
