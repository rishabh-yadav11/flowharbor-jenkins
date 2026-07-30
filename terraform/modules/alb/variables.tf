# =============================================================================
# ALB Module — variables.tf
# =============================================================================
# Input variables for the ALB module.
# =============================================================================

variable "project_name" {
  description = "Project name used for ALB and target group naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB and target groups are created"
  type        = string
}

variable "subnet_ids" {
  description = "List of public subnet IDs (across 2 AZs) for the ALB"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for the ALB (allows HTTPS:443 from internet)"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate for TLS termination on the ALB HTTPS listener"
  type        = string
}

variable "domain_name" {
  description = "Root domain name used to construct host header values in listener rules"
  type        = string
}

variable "jenkins_target_ip" {
  description = "Private IP address of the Jenkins Master EC2 instance for target group attachment"
  type        = string
}
