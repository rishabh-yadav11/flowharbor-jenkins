# =============================================================================
# Route53 Module — outputs.tf
# =============================================================================
# Exported DNS record names for informational purposes.
# =============================================================================

output "jenkins_record" {
  description = "Fully qualified domain name of the Jenkins A record (jenkins.flowharbor.in)"
  value       = aws_route53_record.jenkins.name
}

output "testing_record" {
  description = "Fully qualified domain name of the Testing (dev) A record (testing.flowharbor.in)"
  value       = aws_route53_record.testing.name
}

output "staging_record" {
  description = "Fully qualified domain name of the Staging A record (staging.flowharbor.in)"
  value       = aws_route53_record.staging.name
}

output "root_record" {
  description = "Fully qualified domain name of the Production (root) A record (flowharbor.in)"
  value       = aws_route53_record.root.name
}
