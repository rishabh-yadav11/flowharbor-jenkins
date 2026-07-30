# =============================================================================
# ECR Module — outputs.tf
# =============================================================================
# Exported ECR repository identifiers for consumption by other modules.
# =============================================================================

output "repository_url" {
  description = "Full ECR repository URL (e.g., 123456789012.dkr.ecr.ap-south-1.amazonaws.com/flowharbor-app) — used by Jenkins and ECS task definitions"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ARN of the ECR repository (e.g., arn:aws:ecr:ap-south-1:123456789012:repository/flowharbor-app) — used for IAM policy resource restrictions"
  value       = aws_ecr_repository.this.arn
}
