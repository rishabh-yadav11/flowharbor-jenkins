# =============================================================================
# outputs.tf — Bootstrap Root Module
# =============================================================================
# Print these after `terraform -chdir=terraform/bootstrap apply` and paste
# state_bucket_name and state_kms_key_arn into the root module's commented
# backend block in terraform/backend.tf.
# =============================================================================

output "state_bucket_name" {
  description = "Bucket name for the S3 backend block"
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket"
  value       = aws_s3_bucket.state.arn
}

output "state_kms_key_arn" {
  description = "ARN of the dedicated state CMK — paste into the backend block's kms_key_id"
  value       = aws_kms_key.state.arn
}

output "state_kms_key_id" {
  description = "Key ID of the dedicated state CMK"
  value       = aws_kms_key.state.key_id
}

output "state_kms_alias_name" {
  description = "Alias of the state CMK (use the alias in IAM policies, never the key ID)"
  value       = aws_kms_alias.state.name
}

output "next_steps" {
  description = "Commands that connect the root module to this store"
  value       = <<-EOT
    1. Uncomment the backend "s3" block in terraform/backend.tf and set:
         bucket  = "${aws_s3_bucket.state.id}"
         kms_key_id = "${aws_kms_key.state.arn}"
    2. terraform -chdir=terraform init -migrate-state
    3. terraform -chdir=terraform plan
    Full order and state-recovery procedure: docs/operations.md
  EOT
}
