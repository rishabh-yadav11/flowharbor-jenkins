output "bucket_id" {
  value = aws_s3_bucket.logs.id
}

output "bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

output "bucket_domain_name" {
  value = aws_s3_bucket.logs.bucket_domain_name
}

output "logs_kms_key_arn" {
  value = aws_kms_key.logs.arn
}

output "alerts_topic_arn" {
  description = "ARN of the KMS-encrypted SNS topic that every CloudWatch alarm and the Jenkins pipeline publish to"
  value       = aws_sns_topic.alerts.arn
}
