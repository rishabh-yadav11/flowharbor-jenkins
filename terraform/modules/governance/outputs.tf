# =============================================================================
# Governance Module — outputs.tf
# Exported values from the Governance module.
# =============================================================================

output "config_bucket_name" {
  description = "Name of the AWS Config snapshot bucket"
  value       = aws_s3_bucket.config.id
}

output "config_role_arn" {
  description = "ARN of the Config delivery role — useful for auditing what the delivery path can reach"
  value       = aws_iam_role.config.arn
}

output "config_rule_names" {
  description = "Names of the managed Config rules evaluated in this account"
  value = [
    aws_config_config_rule.encrypted_volumes.name,
    aws_config_config_rule.instances_in_vpc.name,
    aws_config_config_rule.s3_bucket_public_read_prohibited.name
  ]
}

output "securityhub_enabled" {
  description = "Whether the Security Hub account resource is active (aggregates Config and GuardDuty findings)"
  value       = aws_securityhub_account.this.id != ""
}
