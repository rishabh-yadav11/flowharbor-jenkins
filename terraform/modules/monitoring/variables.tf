# =============================================================================
# Monitoring Module — variables.tf
# Input variables for the CloudWatch dashboard and alarm set.
# =============================================================================

variable "project_name" {
  description = "Project name used for the dashboard, alarm, and dimension naming"
  type        = string
}

variable "alerts_topic_arn" {
  description = "ARN of the SNS topic every alarm publishes to (ALARM, OK, and INSUFFICIENT_DATA)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the ECS cluster hosting the dev/staging/prod services"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the shared ALB — the LoadBalancer dimension value is derived from it"
  type        = string
}

variable "prod_target_group_full_name" {
  description = "Full name of the production target group (e.g. flowharbor-prod-tg) — scopes the ALB application metrics"
  type        = string
}

variable "jenkins_master_instance_id" {
  description = "EC2 instance ID of the Jenkins Master — scopes the EC2 health metrics"
  type        = string
}
