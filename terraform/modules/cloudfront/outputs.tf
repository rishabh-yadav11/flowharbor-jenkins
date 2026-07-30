# =============================================================================
# CloudFront Module — outputs.tf
# =============================================================================
# Exported values from the CloudFront module.
# =============================================================================

output "domain_name" {
  description = "CloudFront distribution domain name (e.g., d123.cloudfront.net) — used for Route53 alias record"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "hosted_zone_id" {
  description = "CloudFront hosted zone ID (Z2FDTNDATAQYW2) — required for Route53 A record alias targeting CloudFront"
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}
