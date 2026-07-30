# =============================================================================
# ECS Module — variables.tf
# =============================================================================
# Input variables for the ECS module.
# =============================================================================

variable "project_name" {
  description = "Project name used for naming all ECS resources (cluster, services, task definitions)"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for placing Fargate tasks"
  type        = list(string)
}

variable "ecs_task_sg_id" {
  description = "Security group ID for ECS tasks (allows HTTP:80 from ALB only)"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL for the application Docker image"
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role (for ECR pull and CloudWatch logs)"
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ARN of the ECS task role (for container-level AWS API permissions)"
  type        = string
}

variable "alb_dev_tg_arn" {
  description = "ARN of the ALB dev target group for service registration"
  type        = string
}

variable "alb_staging_tg_arn" {
  description = "ARN of the ALB staging target group for service registration"
  type        = string
}

variable "alb_prod_tg_arn" {
  description = "ARN of the ALB prod target group for service registration"
  type        = string
}
