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

variable "origin_verify_header" {
  description = "HTTP header name the prod listener rule requires (must match CloudFront custom_header name)"
  type        = string
  default     = "X-Origin-Verify"
}

variable "origin_verify_value" {
  description = "Secret header value CloudFront sends for prod traffic. When null/empty the prod rule matches on Host alone (legacy open behavior for enable_cloudfront=false). Set to enforce origin-bypass protection."
  type        = string
  sensitive   = true
  default     = null
}

variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs (issue #13). Empty disables."
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "Prefix for ALB access logs in the bucket"
  type        = string
  default     = "alb"
}

variable "idle_timeout" {
  description = "ALB idle timeout in seconds"
  type        = number
  default     = 60
}
