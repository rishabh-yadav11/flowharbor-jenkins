# =============================================================================
# IAM Module — outputs.tf
# =============================================================================
# Exported IAM resource identifiers for consumption by other modules.
# =============================================================================

output "jenkins_instance_profile_name" {
  description = "Name of the Jenkins EC2 instance profile — used when launching Jenkins Master and Slave instances"
  value       = aws_iam_instance_profile.jenkins.name
}

output "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role — used in ECS task definitions for image pull and log write permissions"
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role — used in ECS task definitions for container-level AWS API permissions"
  value       = aws_iam_role.ecs_task.arn
}
