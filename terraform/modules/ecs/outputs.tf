# =============================================================================
# ECS Module — outputs.tf
# =============================================================================
# Exported values from the ECS module.
# =============================================================================

output "cluster_name" {
  description = "Name of the ECS cluster — used by the Jenkins pipeline for service updates (e.g., flowharbor-cluster)"
  value       = aws_ecs_cluster.this.name
}

output "cluster_id" {
  description = "ID (ARN) of the ECS cluster — useful for cross-module references"
  value       = aws_ecs_cluster.this.id
}
