# =============================================================================
# ACM Module — outputs.tf
# =============================================================================
# Exported certificate ARNs and validation details.
# =============================================================================

output "alb_certificate_arn" {
  description = "ARN of the ACM certificate for the ALB (primary region) — used in the ALB HTTPS listener"
  value       = aws_acm_certificate.alb.arn
}

output "cloudfront_certificate_arn" {
  description = "ARN of the ACM certificate for CloudFront (us-east-1) — used in the CloudFront distribution viewer certificate"
  value       = aws_acm_certificate.cloudfront.arn
}

output "alb_validation_records" {
  description = "DNS validation options for the ALB certificate — useful for debugging validation issues"
  value       = aws_acm_certificate.alb.domain_validation_options
}

output "cloudfront_validation_records" {
  description = "DNS validation options for the CloudFront certificate — useful for debugging validation issues"
  value       = aws_acm_certificate.cloudfront.domain_validation_options
}
