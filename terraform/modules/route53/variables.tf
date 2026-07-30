# =============================================================================
# Route53 Module — variables.tf
# =============================================================================
# Input variables for the Route53 module.
# =============================================================================

variable "domain_name" {
  description = "Root domain name (e.g., flowharbor.in) — subdomains are derived from this"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the domain"
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name — used for jenkins, testing, and staging alias records"
  type        = string
}

variable "alb_zone_id" {
  description = "ALB hosted zone ID — required for ALB alias records"
  type        = string
}

variable "enable_cloudfront" {
  description = "Toggle CloudFront CDN routing for the root domain"
  type        = bool
  default     = true
}

variable "cloudfront_domain_name" {
  description = "CloudFront distribution domain name — used for the root domain alias record"
  type        = string
  default     = ""
}

variable "cloudfront_zone_id" {
  description = "CloudFront hosted zone ID — required for CloudFront alias records (always Z2FDTNDATAQYW2)"
  type        = string
  default     = ""
}
