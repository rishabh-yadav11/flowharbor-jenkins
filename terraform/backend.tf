# =============================================================================
# backend.tf — Terraform Remote State Configuration
# =============================================================================
# This file defines where Terraform stores its state file. By default it uses
# LOCAL state (terraform.tfstate in this directory).
#
# The S3 backend below stays COMMENTED OUT on purpose. A clone must be able to
# run `terraform init -backend=false && terraform validate` with zero AWS
# credentials — that offline check is what the IaC CI job and the README's
# "verified, not asserted" section both depend on. The moment this block is
# live, `terraform init` needs a real account, a real bucket, and real
# credentials, and neither can run on a fork.
#
# To move to shared state (required before more than one person applies):
#   1. Create the state bucket ONCE, with its own dedicated CMK, using the
#      sibling bootstrap module. It cannot live in this module: the backend must
#      exist before state can be written to it, so the configuration that
#      stores its own state cannot also create that store.
#
#        terraform -chdir=terraform/bootstrap init
#        terraform -chdir=terraform/bootstrap apply
#
#      It creates flowharbor-terraform-state with versioning, SSE-KMS on a
#      dedicated key, public access fully blocked, a TLS-only bucket policy,
#      and a 90-day noncurrent-version lifecycle rule.
#
#   2. Copy terraform/bootstrap/terraform.tfvars.example to
#      terraform/bootstrap/terraform.tfvars and set region/bucket_name.
#
#   3. Uncomment the block below and set kms_key_id to the CMK that step 1
#      printed in its outputs.
#   4. Run `terraform -chdir=terraform init -migrate-state` to move the existing
#      local state into S3.
#
#      S3 native locking via use_lockfile=true (TF >= 1.10) replaces the
#      DynamoDB lock table, so there is no second resource to provision.
#
#      The full bootstrap order — including recovering from a corrupted or
#      rolled-back state — is in docs/operations.md.
#
# Security properties of the S3 backend:
#   - Server-side encryption at rest (SSE-KMS with a dedicated CMK) for state
#   - Versioning enabled for recovery/rollback of state
#   - Public access fully blocked
#   - TLS-only bucket policy
#   - S3 native locking via use_lockfile prevents concurrent applies
#   - State never leaves the account and is never committed to git
# =============================================================================

# Local state is the default (no backend block). Uncomment for remote state:
# terraform {
#   backend "s3" {
#     bucket  = "flowharbor-terraform-state"
#     key     = "flowharbor/terraform.tfstate"
#     region  = "ap-south-1"
#     encrypt = true
#     # kms_key_id   = "arn:aws:kms:ap-south-1:<account-id>:key/<cmk-id>"
#     use_lockfile = true
#   }
# }
