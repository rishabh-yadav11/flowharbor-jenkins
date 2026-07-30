# =============================================================================
# Route53 Module — main.tf
# =============================================================================
# This module creates DNS A records in Route53 for the FlowHarbor application.
#
# DNS records created:
#   - jenkins.flowharbor.in  → ALB (alias)
#   - testing.flowharbor.in  → ALB (alias)
#   - staging.flowharbor.in  → ALB (alias)
#   - flowharbor.in          → CloudFront (alias)
#
# All A records use Route53's alias functionality, which is free and provides
# better health-check integration than CNAME records.
# =============================================================================

# ---- Jenkins Subdomain ------------------------------------------------------
# jenkins.flowharbor.in routes to the ALB, which forwards to the Jenkins
# Master instance on port 8080.
resource "aws_route53_record" "jenkins" {
  zone_id = var.hosted_zone_id
  name    = "jenkins.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true # Only route to healthy ALB targets
  }
}

# ---- Testing (Dev) Subdomain ------------------------------------------------
# testing.flowharbor.in routes to the ALB, which forwards to the dev Fargate
# service. This is the auto-deployed environment.
resource "aws_route53_record" "testing" {
  zone_id = var.hosted_zone_id
  name    = "testing.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ---- Staging Subdomain ------------------------------------------------------
# staging.flowharbor.in routes to the ALB, which forwards to the staging
# Fargate service. Requires manual approval to deploy to.
resource "aws_route53_record" "staging" {
  zone_id = var.hosted_zone_id
  name    = "staging.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ---- Root Domain (Production) -----------------------------------------------
# When CloudFront is enabled: flowharbor.in routes through CloudFront, which
# forwards to the ALB. This provides CDN caching, edge TLS termination, and
# DDoS protection.
# When CloudFront is disabled: flowharbor.in routes directly to the ALB.
locals {
  root_alias_name    = var.enable_cloudfront ? var.cloudfront_domain_name : var.alb_dns_name
  root_alias_zone_id = var.enable_cloudfront ? var.cloudfront_zone_id : var.alb_zone_id
  root_health_check  = var.enable_cloudfront ? false : true
}

resource "aws_route53_record" "root" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = local.root_alias_name
    zone_id                = local.root_alias_zone_id
    evaluate_target_health = local.root_health_check
  }
}
