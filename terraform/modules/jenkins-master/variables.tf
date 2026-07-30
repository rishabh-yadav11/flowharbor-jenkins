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
  description = "IAM instance profile name for EC2 (provides SSM, ECR, ECS permissions)"
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
