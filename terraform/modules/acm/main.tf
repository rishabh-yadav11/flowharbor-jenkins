# =============================================================================
# ACM Module — main.tf
# =============================================================================
# This module provisions TLS certificates via AWS Certificate Manager (ACM)
# for both the ALB and CloudFront. DNS validation is used via Route53 records.
#
# Why two certificates?
#   AWS requires that certificates used with CloudFront be provisioned in the
#   us-east-1 region. Certificates used with ALB can be in the local region.
#   Therefore, we create two certificates:
#     1. ALB certificate         — in the primary region (e.g., ap-south-1)
#        Domain: flowharbor.in + *.flowharbor.in (wildcard for subdomains)
#     2. CloudFront certificate   — in us-east-1
#        Domain: flowharbor.in (root domain only for CDN)
# =============================================================================

# ---- Provider Configuration -------------------------------------------------
# This module requires two AWS provider configurations. The module declares
# the alias requirement so Terraform knows it expects two providers.
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# ---- ALB Certificate (Primary Region) ---------------------------------------
# A public certificate for the primary region. This terminates TLS at the ALB.
# It includes both the root domain and a wildcard for all subdomains
# (jenkins.*, testing.*, staging.*).
resource "aws_acm_certificate" "alb" {
  domain_name               = var.domain_name          # flowharbor.in
  subject_alternative_names = ["*.${var.domain_name}"] # *.flowharbor.in
  validation_method         = "DNS"                    # Validate via Route53 records
  provider                  = aws                      # Use the default (primary region) provider

  tags = {
    Name = "${var.domain_name}-alb-cert"
  }
}

# ---- CloudFront Certificate (us-east-1) -------------------------------------
# A public certificate in us-east-1 required by CloudFront. Only the root
# domain is covered since only the production URL goes through CloudFront.
resource "aws_acm_certificate" "cloudfront" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  provider          = aws.us_east_1 # Must be in us-east-1 for CloudFront

  tags = {
    Name = "${var.domain_name}-cloudfront-cert"
  }
}

# ---- DNS Validation Records (ALB) -------------------------------------------
# For each domain validation option on the ALB certificate, create a DNS
# record in Route53. ACM provides the CNAME name/value pairs that prove
# domain ownership.
resource "aws_route53_record" "alb_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true # Allow overwriting if records already exist (re-deployment)
}

# ---- DNS Validation Records (CloudFront) ------------------------------------
# Same as above, but for the CloudFront certificate (in us-east-1).
# The validation records are created in the same Route53 zone regardless of
# which region the certificate lives in.
resource "aws_route53_record" "cloudfront_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# ---- Certificate Validation (ALB) -------------------------------------------
# Waits for the ALB certificate validation to complete. The depends_on
# relationship between the validation and the Route53 records ensures
# Terraform creates the DNS records first, then waits for validation.
resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_validation : record.fqdn]
}

# ---- Certificate Validation (CloudFront) ------------------------------------
# Waits for the CloudFront certificate validation to complete.
resource "aws_acm_certificate_validation" "cloudfront" {
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.cloudfront_validation : record.fqdn]
  provider                = aws.us_east_1
}
