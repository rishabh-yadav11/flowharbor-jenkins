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

# ---- Origin Subdomain (CloudFront → ALB) -----------------------------------
# origin.<domain> is the cert-matched hostname CloudFront uses as its origin
# (see cloudfront module). The wildcard ACM cert (*.<domain>) covers it, so
# the https-only origin TLS handshake validates — using the raw ALB DNS name
# would fail verification. Never point end users here; it exists so the
# origin has a hostname the ALB certificate actually serves.
resource "aws_route53_record" "origin" {
  zone_id = var.hosted_zone_id
  name    = "origin.${var.domain_name}"
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

# ---- IPv6 (AAAA) Aliases (issue #19) ------------------------------------------
# Mirror every A alias with an AAAA alias so dual-stack clients resolve over
# IPv6. CloudFront/ALB alias targets are dual-stack capable.
resource "aws_route53_record" "jenkins_aaaa" {
  zone_id = var.hosted_zone_id
  name    = "jenkins.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "testing_aaaa" {
  zone_id = var.hosted_zone_id
  name    = "testing.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "staging_aaaa" {
  zone_id = var.hosted_zone_id
  name    = "staging.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "origin_aaaa" {
  zone_id = var.hosted_zone_id
  name    = "origin.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "root_aaaa" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = local.root_alias_name
    zone_id                = local.root_alias_zone_id
    evaluate_target_health = local.root_health_check
  }
}

# ---- CAA (issue #19) ----------------------------------------------------------
# Restrict certificate issuance for the apex to Amazon only.
resource "aws_route53_record" "caa" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "CAA"
  ttl     = 300
  records = [
    "0 issue \"amazon.com\"",
    "0 issuewild \"amazon.com\"",
  ]
}

# ---- DNSSEC (issue #19, opt-in) -----------------------------------------------
# Disabled by default (enable_dnssec=false). Enabling requires the hosted
# zone to be signed; the KSK must use an ECC_NIST_P256 key in us-east-1.
# NOTE: aws_kms_key must be created in us-east-1 for Route53 DNSSEC — apply
# this module with a us-east-1 provider alias when enable_dnssec=true.
resource "aws_kms_key" "dnssec" {
  count                    = var.enable_dnssec ? 1 : 0
  description              = "Route53 DNSSEC KSK for ${var.domain_name}"
  deletion_window_in_days  = 7
  enable_key_rotation      = false
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Allow Route53 DNSSEC"
        Effect    = "Allow"
        Principal = { Service = "dnssec-route53.amazonaws.com" }
        Action    = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign", "kms:Verify"]
        Resource  = "*"
      },
      {
        Sid       = "Enable IAM User Permissions"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })
}

resource "aws_route53_key_signing_key" "this" {
  count                      = var.enable_dnssec ? 1 : 0
  hosted_zone_id             = var.hosted_zone_id
  key_management_service_arn = aws_kms_key.dnssec[0].arn
  name                       = "ksk"
  status                     = "ACTIVE"
}

resource "aws_route53_hosted_zone_dnssec" "this" {
  count          = var.enable_dnssec ? 1 : 0
  hosted_zone_id = var.hosted_zone_id
  signing_status = "SIGNING"
  depends_on     = [aws_route53_key_signing_key.this]
}
