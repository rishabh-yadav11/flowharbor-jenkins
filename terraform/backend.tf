# =============================================================================
# backend.tf — Terraform Remote State Configuration
# =============================================================================
# This file defines where Terraform stores its state file. By default it uses
# LOCAL state (terraform.tfstate in this directory) for zero-setup demo use.
# Local state is NOT recommended for team/prod — it can be lost, is not
# locked across machines, and may contain sensitive values. For shared use,
# enable the S3 backend below.
#
# To enable remote state with S3 (recommended for security & collaboration):
#   1. Create the state bucket ONCE using the AWS CLI/console
#      (it must exist BEFORE terraform init). Do NOT put it in this module
#      — the backend must be configured before state can be written to it.
#
#      export AWS_REGION=ap-south-1 STATE_BUCKET=flowharbor-terraform-state
#      aws s3api create-bucket --bucket $STATE_BUCKET --region $AWS_REGION \
#        --create-bucket-configuration LocationConstraint=$AWS_REGION
#      aws s3api put-bucket-versioning --bucket $STATE_BUCKET \
#        --versioning-configuration Status=Enabled
#      aws s3api put-bucket-encryption --bucket $STATE_BUCKET \
#        --server-side-encryption-configuration '{
#            "Rules": [{ "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "aws:kms", "KMSMasterKeyID": "arn:aws:kms:ap-south-1:<account-id>:key/<cmk-id>" } }]
#        }'
#      aws s3api put-public-access-block --bucket $STATE_BUCKET \
#        --public-access-block-configuration '{
#            "BlockPublicAcls": true, "IgnorePublicAcls": true,
#            "BlockPublicPolicy": true, "RestrictPublicBuckets": true
#        }'
#      # plus TLS-only bucket policy (Deny s3:* when aws:SecureTransport=false)
#
#   2. Uncomment the block below (set kms_key_id to your CMK).
#   3. Run `terraform init -migrate-state` to copy local state to S3.
#      S3 native locking via use_lockfile=true (TF >= 1.10) replaces DynamoDB.
#
# Security properties of the S3 backend:
#   - Server-side encryption at rest (SSE-KMS with CMK) for the state file
#   - Versioning enabled for recovery/rollback of state
#   - Public access fully blocked + BucketOwnerEnforced
#   - TLS-only bucket policy
#   - S3 native locking via use_lockfile prevents concurrent applies
#   - State never leaves the account or gets committed to git
# =============================================================================

# Local state is the default (no backend block). Uncomment for remote state:
# terraform {
#   backend "s3" {
#     bucket  = "flowharbor-terraform-state"
#     key     = "jenkins-demo/terraform.tfstate"
#     region  = "ap-south-1"
#     encrypt = true
#     # kms_key_id   = "arn:aws:kms:ap-south-1:<account-id>:key/<cmk-id>"
#     use_lockfile = true
#   }
# }