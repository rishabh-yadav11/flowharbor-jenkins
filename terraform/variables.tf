# =============================================================================
# variables.tf — FlowHarbor Root Module Variables
# =============================================================================
# These are the top-level input variables that configure the entire FlowHarbor
# infrastructure deployment. Most have sensible defaults; the two required
# variables (domain_name and hosted_zone_id) are typically provided via a
# terraform.tfvars file or CI/CD environment variables.
# =============================================================================

# ---- AWS Region -------------------------------------------------------------
# The primary region where most infrastructure resources will be created.
# Certificate for CloudFront is an exception — it must be in us-east-1.
variable "aws_region" {
  description = "AWS region for all primary resources (ap-south-1 = Mumbai)"
  type        = string
  default     = "ap-south-1"
}

# ---- Project Name -----------------------------------------------------------
# Used as a prefix/tag for all resources to enable identification and
# cost tracking. Also used in SSM parameter paths and ECS resource names.
variable "project_name" {
  description = "Project name used for resource naming and tagging across all modules"
  type        = string
  default     = "flowharbor"
}

# ---- Domain Name ------------------------------------------------------------
# The root domain for the application. Must be a Route53-managed domain or
# a domain whose DNS is hosted in the referenced Route53 hosted zone.
# Subdomains are derived from this: jenkins., testing., staging.
variable "domain_name" {
  description = "Root domain name (e.g., flowharbor.in) — must be configured in Route53"
  type        = string
}

# ---- Route53 Hosted Zone ----------------------------------------------------
# The ID of the Route53 hosted zone for the domain. This is required for
# creating DNS validation records (ACM) and A record aliases.
variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the domain — found in the AWS Route53 console"
  type        = string
}

# ---- VPC CIDR ---------------------------------------------------------------
# The IP address range for the VPC. /16 provides 65,536 IP addresses, which is
# more than sufficient for this demo. Subnet CIDRs are derived automatically
# using cidrsubnet() in the VPC module.
variable "vpc_cidr" {
  description = "VPC CIDR block (e.g., 10.0.0.0/16) — subnets are auto-derived"
  type        = string
  default     = "10.0.0.0/16"
}

# ---- CloudFront Toggle -------------------------------------------------------
# Controls whether a CloudFront CDN distribution is placed in front of the ALB
# for production traffic. When enabled, the root domain (flowharbor.in) routes
# through CloudFront. When disabled, it routes directly to the ALB.
# Disabling this can simplify debugging and reduce costs during development.
variable "enable_cloudfront" {
  description = "Toggle CloudFront CDN for production traffic (true = enabled, false = disabled)"
  type        = bool
  default     = false
}

# ---- CloudFront Origin-Bypass Guard (issue #3) -------------------------------
# Secret value CloudFront sends as X-Origin-Verify and the ALB prod rule
# requires. Required when enable_cloudfront=true; ignored otherwise.
# Generate with: openssl rand -hex 32
# Pass via env (TF_VAR_cloudfront_origin_verify_token) or tfvars — never commit.
variable "cloudfront_origin_verify_token" {
  description = "Secret for the CloudFront origin-verify header (issue #3). Required when enable_cloudfront=true."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = !var.enable_cloudfront || (var.cloudfront_origin_verify_token != null && length(trimspace(coalesce(var.cloudfront_origin_verify_token, ""))) >= 32)
    error_message = "cloudfront_origin_verify_token must be set to a secret >= 32 chars when enable_cloudfront=true (generate with: openssl rand -hex 32)."
  }
}

# ---- ALB Network Restriction (issue #3) --------------------------------------
# See security-groups module: strict CloudFront-only SG breaks direct hosts
# on a single-ALB stack. Keep false until prod is split to a dedicated ALB.
variable "alb_restrict_to_cloudfront" {
  description = "Restrict ALB 80/443 SG ingress to the CloudFront origin-facing prefix list only (breaks direct jenkins/testing/staging on a single ALB)"
  type        = bool
  default     = false
}
