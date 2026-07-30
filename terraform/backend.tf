# =============================================================================
# backend.tf — Terraform Remote State Configuration
# =============================================================================
# This file defines where Terraform stores its state file. Currently, the
# backend is commented out, which means Terraform uses local state storage
# (terraform.tfstate in this directory). This is fine for single-operator
# demos but is NOT recommended for team use.
#
# To enable remote state with S3 (recommended for production):
#   1. Create an S3 bucket (e.g., flowharbor-terraform-state) with versioning enabled
#   2. Create a DynamoDB table (e.g., flowharbor-terraform-locks) for state locking
#   3. Uncomment the block below
#   4. Run `terraform init -migrate-state` to copy the local state to S3
#
# Benefits of remote state:
#   - Team collaboration: multiple operators can run terraform safely
#   - State locking: prevents concurrent modifications (via DynamoDB)
#   - Backup & recovery: S3 versioning provides state file history
#   - CI/CD integration: pipelines can read/write state
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
