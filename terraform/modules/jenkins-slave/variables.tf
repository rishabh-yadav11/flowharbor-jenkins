# =============================================================================
# Jenkins Slave Module — variables.tf
# =============================================================================
# Input variables for the Jenkins Slave module.
# =============================================================================

variable "project_name" {
  description = "Project name used for instance naming"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID for the Jenkins Slave instance (should be in the second AZ)"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the Jenkins Slave instance (outbound-only access)"
  type        = string
}

variable "iam_instance_profile" {
  description = "IAM instance profile name for EC2 (provides SSM, ECR permissions)"
  type        = string
}
