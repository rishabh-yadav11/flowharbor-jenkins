# =============================================================================
# Security Groups Module — outputs.tf
# =============================================================================
# Exported security group IDs for consumption by other modules.
# =============================================================================

output "alb_sg_id" {
  description = "Security group ID for the ALB — attached to the ALB resource"
  value       = aws_security_group.alb.id
}

output "jenkins_master_sg_id" {
  description = "Security group ID for the Jenkins Master EC2 instance"
  value       = aws_security_group.jenkins_master.id
}

output "jenkins_slave_sg_id" {
  description = "Security group ID for the Jenkins Slave EC2 instance"
  value       = aws_security_group.jenkins_slave.id
}

output "ecs_tasks_sg_id" {
  description = "Security group ID for ECS Fargate tasks — attached to ECS service network configurations"
  value       = aws_security_group.ecs_tasks.id
}
