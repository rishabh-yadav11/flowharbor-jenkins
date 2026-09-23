# =============================================================================
# Monitoring Module — outputs.tf
# Exported values from the Monitoring module.
# =============================================================================

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard (open it with the console's Dashboards menu)"
  value       = aws_cloudwatch_dashboard.app.dashboard_name
}

output "dashboard_arn" {
  description = "ARN of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.app.dashboard_arn
}

output "alarm_arns" {
  description = "ARNs of every alarm in the set — pass these to any external notifier (ChatOps, PagerDuty)"
  value = [
    aws_cloudwatch_metric_alarm.ecs_prod_cpu_high.arn,
    aws_cloudwatch_metric_alarm.ecs_prod_memory_high.arn,
    aws_cloudwatch_metric_alarm.alb_prod_5xx.arn,
    aws_cloudwatch_metric_alarm.alb_prod_latency.arn,
    aws_cloudwatch_metric_alarm.alb_prod_unhealthy.arn,
    aws_cloudwatch_metric_alarm.waf_blocked_spike.arn,
    aws_cloudwatch_metric_alarm.jenkins_master_unreachable.arn
  ]
}

output "alarm_names" {
  description = "Names of every alarm in the set (for CLI lookups: aws cloudwatch describe-alarms --alarm-name)"
  value = [
    aws_cloudwatch_metric_alarm.ecs_prod_cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.ecs_prod_memory_high.alarm_name,
    aws_cloudwatch_metric_alarm.alb_prod_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.alb_prod_latency.alarm_name,
    aws_cloudwatch_metric_alarm.alb_prod_unhealthy.alarm_name,
    aws_cloudwatch_metric_alarm.waf_blocked_spike.alarm_name,
    aws_cloudwatch_metric_alarm.jenkins_master_unreachable.alarm_name
  ]
}
