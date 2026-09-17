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

variable "origin_verify_header" {
  description = "HTTP header name CloudFront sends and the ALB validates to prove origin traffic came through the CDN"
  type        = string
  default     = "X-Origin-Verify"
}

variable "origin_verify_value" {
  description = "Secret value for the origin-verify header. Generate with `openssl rand -hex 32` and pass via TF_VAR / tfvars (never commit). Must match the ALB listener-rule condition."
  type        = string
  sensitive   = true
  default     = null
}

variable "logging_bucket_domain" {
  description = "S3 bucket domain for CloudFront access logging (issue #13). Empty disables."
  type        = string
  default     = ""
}

variable "logging_prefix" {
  description = "Prefix for CloudFront logs"
  type        = string
  default     = "cf"
}

variable "web_acl_id" {
  description = "CLOUDFRONT-scope WAF Web ACL ARN (issue #13). Empty = none."
  type        = string
  default     = ""
}
