# =============================================================================
# CloudFront Module — variables.tf
# =============================================================================
# Input variables for the CloudFront module.
# =============================================================================

variable "domain_name" {
  description = "Root domain name (e.g., flowharbor.in) — used as the CloudFront CNAME alias"
  type        = string
}

variable "alb_domain_name" {
  description = "ALB DNS name — the origin that CloudFront forwards requests to"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate in us-east-1 for CloudFront viewer HTTPS"
  type        = string
}

variable "project_name" {
  description = "Project name used as a prefix for cache/origin request policy naming"
  type        = string
}
