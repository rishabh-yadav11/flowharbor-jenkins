# =============================================================================
# ALB Module — outputs.tf
# =============================================================================
# Exported values from the ALB module.
# =============================================================================

output "dns_name" {
  description = "DNS name of the ALB — used for Route53 alias records and CloudFront origin"
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "Canonical hosted zone ID of the ALB — required for Route53 alias record creation"
  value       = aws_lb.this.zone_id
}

output "listener_arn" {
  description = "ARN of the HTTPS listener — useful for adding additional listener rules programmatically"
  value       = aws_lb_listener.https.arn
}

output "dev_target_group_arn" {
  description = "ARN of the Dev target group — used by the ECS module for dev service load balancer configuration"
  value       = aws_lb_target_group.dev.arn
}

output "staging_target_group_arn" {
  description = "ARN of the Staging target group — used by the ECS module for staging service load balancer configuration"
  value       = aws_lb_target_group.staging.arn
}

output "prod_target_group_arn" {
  description = "ARN of the Production target group — used by the ECS module for prod service load balancer configuration"
  value       = aws_lb_target_group.prod.arn
}
