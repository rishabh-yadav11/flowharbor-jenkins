# =============================================================================
# ACM Module — variables.tf
# =============================================================================
# Input variables for the ACM module.
# =============================================================================

variable "domain_name" {
  description = "Root domain name (e.g., flowharbor.in) — both the root and wildcard (*.) are added to the ALB certificate"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the domain — DNS validation records are created in this zone"
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region for the ALB certificate (the CloudFront certificate always uses us-east-1)"
  type        = string
}
