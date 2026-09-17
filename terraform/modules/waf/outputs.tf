# =============================================================================
# WAF Module — outputs.tf
# =============================================================================
# Exported values from the WAF module.
# =============================================================================

output "web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL associated with the shared ALB"
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "ID of the WAFv2 Web ACL associated with the shared ALB"
  value       = aws_wafv2_web_acl.this.id
}

output "jenkins_allowlist_arn" {
  description = "ARN of the Jenkins IP allowlist IP set"
  value       = aws_wafv2_ip_set.jenkins_allowlist.arn
}
