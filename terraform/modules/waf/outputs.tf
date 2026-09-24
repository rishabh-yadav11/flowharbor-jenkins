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

output "cloudfront_web_acl_arn" {
  description = "ARN of the CLOUDFRONT-scope Web ACL (empty string when enable_cloudfront is false)"
  value       = try(aws_wafv2_web_acl.cloudfront[0].arn, "")
}

output "logs_log_group_name" {
  description = "Name of the WAF request-log log group — where to read which rule blocked a request"
  value       = aws_cloudwatch_log_group.alb.name
}
