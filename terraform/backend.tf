# =============================================================================
# backend.tf — Terraform Remote State Configuration
# =============================================================================
# This file defines where Terraform stores its state file. Currently, the
# backend is commented out, which means Terraform uses local state storage
# (terraform.tfstate in this directory). This is NOT recommended — local state
# can be lost, is not locked, and may contain sensitive output values.
#
# To enable remote state with S3 (recommended for security & collaboration):
#   1. Create the state bucket and lock table ONCE using the AWS CLI/console
#      (they must exist BEFORE terraform init). Do NOT put them in this module
#      — the backend must be configured before state can be written to it.
#
#      aws s3api create-bucket --bucket flowharbor-terraform-state \
#          --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1
#      aws s3api put-bucket-versioning \
#          --bucket flowharbor-terraform-state --versioning-configuration Status=Enabled
#      aws s3api put-bucket-encryption \
#          --bucket flowharbor-terraform-state \
#          --server-side-encryption-configuration '{
#              "Rules": [{ "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" } }]
#          }'
#      aws s3api put-public-access-block \
#          --bucket flowharbor-terraform-state \
#          --public-access-block-configuration '{
#              "BlockPublicAcls": true, "IgnorePublicAcls": true,
#              "BlockPublicPolicy": true, "RestrictPublicBuckets": true
#          }'
#      aws dynamodb create-table \
#          --table-name flowharbor-terraform-locks \
#          --attribute-definitions AttributeName=LockID,AttributeType=S \
#          --key-schema AttributeName=LockID,KeyType=HASH \
#          --billing-mode PAY_PER_REQUEST
#
#   2. Uncomment the block below.
#   3. Run `terraform init -migrate-state` to copy the local state to S3.
#
# Security properties of the recommended backend:
#   - Server-side encryption at rest (AES256) for the state file
#   - Versioning enabled for recovery/rollback of state
#   - Public access fully blocked
#   - DynamoDB lock table prevents concurrent/conflicting apply operations
#   - State never leaves the account or gets committed to git
# =============================================================================

# Uncomment and configure for remote state management
# terraform {
#   backend "s3" {
#     bucket         = "flowharbor-terraform-state"
#     key            = "jenkins-demo/terraform.tfstate"
#     region         = "ap-south-1"
#     encrypt        = true
#     dynamodb_table = "flowharbor-terraform-locks"
#   }
# }