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
