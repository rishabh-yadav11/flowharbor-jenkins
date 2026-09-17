# =============================================================================
# ECS Module — autoscaling.tf (issue #10)
# Target-tracking autoscaling for staging/prod (dev included with min=1).
# =============================================================================

locals {
  autoscale_envs = ["dev", "staging", "prod"]
  ecs_services = {
    dev     = aws_ecs_service.dev.name
    staging = aws_ecs_service.staging.name
    prod    = aws_ecs_service.prod.name
  }
}

resource "aws_appautoscaling_target" "this" {
  for_each           = toset(local.autoscale_envs)
  max_capacity       = var.max_capacity[each.key]
  min_capacity       = var.min_capacity[each.key]
  resource_id        = "service/${aws_ecs_cluster.this.name}/${local.ecs_services[each.key]}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each           = toset(local.autoscale_envs)
  name               = "${var.project_name}-${each.key}-cpu-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "memory" {
  for_each           = toset(local.autoscale_envs)
  name               = "${var.project_name}-${each.key}-memory-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 75.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
