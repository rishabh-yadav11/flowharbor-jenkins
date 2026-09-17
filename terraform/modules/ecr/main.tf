# =============================================================================
# ECR Module — main.tf
# =============================================================================
# This module creates a private Elastic Container Registry (ECR) repository
# for the FlowHarbor application Docker images.
#
# Features:
#   - Immutable image tags (blocks overwriting release tags and :latest)
#   - Scan images for vulnerabilities on push
#   - Lifecycle policy to clean up untagged images (keep last 10) + bound tagged history
#   - Force delete enabled for easy teardown in demo environments
# =============================================================================

# ---- ECR Repository ---------------------------------------------------------
# A private Docker image registry for the FlowHarbor application.
# image_tag_mutability = "IMMUTABLE" blocks tag overwrites — pipeline deploys
# by digest (repo@sha256:...), never by mutable :latest.
# force_delete = false prevents `terraform destroy` from silently wiping
# container images (a destructive, non-recoverable action).
resource "aws_ecr_repository" "this" {
  name                 = "${var.project_name}-app" # Repository name: flowharbor-app
  image_tag_mutability = "IMMUTABLE"               # Block tag overwrites
  force_delete         = false                     # Protect images from accidental deletion

  # Automatically scan images for vulnerabilities when they are pushed.
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-app-repo"
  }
}

# ---- Lifecycle Policy -------------------------------------------------------
# Clean up old untagged images to save storage costs. Untagged images
# accumulate when manifests are re-pushed. Keep last 10 untagged.
# Bound tagged history to the 50 most recent images to prevent unbounded growth.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 untagged images to control storage costs"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire" # Delete images exceeding the count
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 50 tagged images (semver + prerelease/build metadata)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = 50
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
