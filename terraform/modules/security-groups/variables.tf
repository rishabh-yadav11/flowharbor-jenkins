# =============================================================================
# Security Groups Module — variables.tf
# =============================================================================
# Input variables for the security groups module.
# =============================================================================

variable "vpc_id" {
  description = "ID of the VPC where all security groups will be created"
  type        = string
}

variable "project_name" {
  description = "Project name used as a prefix for security group naming and tagging"
  type        = string
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks of private subnets (reserved for future use, e.g., allowing internal traffic between private resources)"
  type        = list(string)
}

variable "alb_restrict_to_cloudfront" {
  description = "When true, ALB 80/443 ingress allows ONLY the CloudFront origin-facing managed prefix list. WARNING: this breaks direct-to-ALB hosts (jenkins/testing/staging) on a single-ALB stack — only enable after splitting prod onto a dedicated ALB. Default false keeps 0.0.0.0/0 so direct hosts work; prod bypass is then blocked at L7 by the ALB secret-header rule."
  type        = bool
  default     = false
}
