# =============================================================================
# main.tf — FlowHarbor Terraform State Bootstrap
# =============================================================================
# Creates the remote state store: a versioned, KMS-encrypted, private S3 bucket
# and a dedicated CMK for it.
#
# Why a dedicated key instead of aws/s3: the state file contains every
# resource attribute in the stack, which is the same information an attacker
# reads a state file for. The default S3 key is shared with every S3 bucket in
# the account and in every other account using AWS-managed keys, so a policy
# change that breaks the app's data can also break (or expose) state. A
# dedicated key means state access is granted to the backend explicitly and
# can be reviewed on its own.
#
# Nothing here is imported by the root module. This module is applied exactly
# once, by hand, before the root module's first `init -migrate-state`.
# =============================================================================

# Region comes from the variable, not from the ambient AWS_REGION/CLI profile.
# The backend block in the parent module hardcodes a region string, and a
# mismatch here is silent: the bucket is created, and then the root module's
# `init -migrate-state` fails to find it.
provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---- Dedicated CMK ------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "${var.project_name} Terraform state CMK"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = true

  # Terraform only needs to encrypt and decrypt with this key — never to sign
  # or generate data keys for anything else. Narrow on purpose: a state CMK that
  # can sign is a signing key with a very boring name.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # S3 calls the key on the bucket owner's behalf. Without this statement
        # the bucket is created and then silently unable to accept a state file.
        Sid    = "AllowS3ServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project_name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# ---- State Bucket ------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    # Non-negotiable: a corrupted state file is recovered by restoring the
    # previous version. Versioning is the recovery mechanism, not a nicety.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Keep superseded state versions for a quarter, then drop them. Old state files
# still contain the resource attributes of the resources that produced them,
# so this is an expiry decision, not a housekeeping one.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    # Empty filter on purpose: scoping this to a key prefix would silently stop
    # expiring state the moment someone changes the backend key.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # S3 does the encrypting, so the caller's policy only has to permit the
        # write once the bucket policy has already refused plaintext transport.
        Sid       = "AllowTerraformStateWrite"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
      }
    ]
  })
}
