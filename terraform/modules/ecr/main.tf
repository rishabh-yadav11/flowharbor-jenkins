# =============================================================================
# ECR Module — main.tf
# =============================================================================
# This module creates a private Elastic Container Registry (ECR) repository
# for the FlowHarbor application Docker images.
#
# Features:
#   - Mutable image tags (allows overwriting ":latest")
#   - Scan images for vulnerabilities on push
#   - Lifecycle policy to clean up untagged images (keep last 10)
#   - Force delete enabled for easy teardown in demo environments
# =============================================================================

# ---- ECR Repository ---------------------------------------------------------
# A private Docker image registry for the FlowHarbor application.
# image_tag_mutability = "MUTABLE" allows overwriting tags (e.g., ":latest").
# NOTE: IMMUTABLE is the safer default, but the pipeline pushes ":latest" on
# every build. If you switch to IMMUTABLE, stop tagging with ":latest" first.
# force_delete = false prevents `terraform destroy` from silently wiping
# container images (a destructive, non-recoverable action).
resource "aws_ecr_repository" "this" {
  name                 = "${var.project_name}-app" # Repository name: flowharbor-app
  image_tag_mutability = "MUTABLE"                 # Allow overwriting tags
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
# accumulate when we push new ":latest" tags without cleaning up the previous
# ones. This policy keeps only the 10 most recent untagged images.
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
      }
    ]
  })
}
