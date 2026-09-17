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
  description = "Security group ID for ECS tasks (allows HTTP:3000 from ALB only)"
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

variable "initial_image_tag" {
  description = "Bootstrap image tag for initial task definitions only. Runtime image is managed by Jenkins promote() via digest (repo@sha256:...). Never use :latest."
  type        = string
  default     = "0.0.0-bootstrap"
}

variable "desired_count" {
  description = "Desired task count per environment"
  type        = map(number)
  default = {
    dev     = 1
    staging = 2
    prod    = 2
  }
}

variable "min_capacity" {
  description = "Min autoscaling capacity per environment"
  type        = map(number)
  default = {
    dev     = 1
    staging = 2
    prod    = 2
  }
}

variable "max_capacity" {
  description = "Max autoscaling capacity per environment"
  type        = map(number)
  default = {
    dev     = 2
    staging = 4
    prod    = 6
  }
}

variable "enable_execute_command" {
  description = "Enable ECS exec. True requires KMS logging config; false disables for least privilege."
  type        = bool
  default     = false
}

variable "ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix for per-env container secrets (e.g. /flowharbor/dev/GIT_AUTHOR). Jenkins promote() writes values; Terraform owns the skeleton."
  type        = string
  default     = "/flowharbor"
}

variable "log_kms_key_id" {
  description = "KMS key ARN for CloudWatch log group encryption (wired from observability_logging module). Null disables encryption."
  type        = string
  default     = null
}
