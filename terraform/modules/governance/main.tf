# =============================================================================
# Governance Module — main.tf
# Continuous compliance: AWS Config records the account's configuration and
# evaluates it, Security Hub aggregates the findings.
#
# What this buys that GuardDuty (already in the root module) does not:
#   - GuardDuty finds malicious ACTIVITY (threat intelligence).
#   - Config finds DRIFT (unencrypted volumes, public buckets, instances
#     launched outside the VPC). It is the difference between "our infra is
#     secure" and "our infra is still secure as of the last change".
#
# The three managed rules below are ADVISORY on purpose. A non-zero compliance
# count on a demo stack is a signal, not a page: turning them into
# COMPLIANT-breach rules would page the on-call for a rule nobody has
# suppressed yet. The CloudWatch alarms are the paging path.
# =============================================================================

# ---- Data Sources -----------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# =============================================================================
# Config Snapshot Bucket
# =============================================================================
# A dedicated bucket, not the shared log bucket: the Config delivery role needs
# write access to exactly this prefix, and widening it to a shared bucket would
# widen the role too.

resource "aws_s3_bucket" "config" {
  bucket = "${var.project_name}-config-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Config snapshots are overwritten in place; expire them after a year. Compliance
# history that matters is already in the Config timeline, so the snapshot copy
# is evidence, not a system of record.
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = ["${aws_s3_bucket.config.arn}", "${aws_s3_bucket.config.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

# =============================================================================
# Config Delivery Role
# =============================================================================
# Config assumes this role to write snapshots. It can write to this bucket and
# use this one key — nothing else, so the delivery path cannot be repurposed to
# read any other bucket in the account.

data "aws_iam_policy_document" "config_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "${var.project_name}-config-role"
  assume_role_policy = data.aws_iam_policy_document.config_assume_role.json

  tags = {
    Name = "${var.project_name}-config-role"
  }
}

resource "aws_iam_role_policy" "config_delivery" {
  name = "${var.project_name}-config-delivery"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.config.arn,
          "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# =============================================================================
# Recorder + Delivery Channel
# =============================================================================
# all_supported records every resource type AWS Config knows, including global
# ones (IAM, S3 buckets, Route53 zones) that have no regional home. A recorder
# scoped to a few resource types is a recorder that misses the interesting
# drift.
resource "aws_config_configuration_recorder" "this" {
  name     = "${var.project_name}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "${var.project_name}-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id
  # The delivery role lives on the recorder above: the provider models AWS
  # Config's current one-role-per-recorder behaviour, so this resource takes
  # only the bucket and snapshot cadence.

  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

# =============================================================================
# Managed Rules
# =============================================================================
# Three rules, each answering a question a reviewer of this repo would ask:
#   ENCRYPTED_VOLUMES                — is any EBS volume unencrypted?
#   INSTANCES_IN_VPC                 — can an EC2 instance land outside the VPC?
#   S3_BUCKET_PUBLIC_READ_PROHIBITED — is any bucket publicly readable?

resource "aws_config_config_rule" "encrypted_volumes" {
  name = "${var.project_name}-encrypted-volumes"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }


  # No compliance_type override: the managed rule's own definition decides how
  # it reports, and forcing a scope block here would only narrow it.
}

resource "aws_config_config_rule" "instances_in_vpc" {
  name = "${var.project_name}-instances-in-vpc"

  source {
    owner             = "AWS"
    source_identifier = "INSTANCES_IN_VPC"
  }


}

resource "aws_config_config_rule" "s3_bucket_public_read_prohibited" {
  name = "${var.project_name}-s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }


}

# =============================================================================
# Security Hub
# =============================================================================
# Security Hub is the aggregation layer: without it, Config findings stay in the
# Config console and nobody looks there. The foundational standard is the one
# AWS itself checks new accounts against, and it is nearly all free.
resource "aws_securityhub_account" "this" {}

resource "aws_securityhub_standards_subscription" "foundational" {
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v1.0.0"

  # The subscription API call is rejected until the account resource has
  # finished enabling Security Hub, and nothing in the argument list would
  # otherwise make Terraform order them. An explicit edge beats an apply that
  # fails intermittently on a cold account.
  depends_on = [aws_securityhub_account.this]
}
