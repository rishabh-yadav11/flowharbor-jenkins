# =============================================================================
# Monitoring Module — main.tf
# One operator dashboard plus the seven alarms that page a human.
#
# Why the dashboard and the alarms are separate objects: the dashboard is what
# an operator opens during an incident (all six signals side by side), while the
# alarms are the fail-closed delivery path — every alarm has an explicit
# `ok_actions` as well as `alarm_actions`, so a RESOLVED notification is
# published too, and `treat_missing_data = "notBreaching"` keeps a gap in
# scraping from masquerading as an outage.
#
# Alarms (name suffix → metric → condition):
#   ecs-prod-cpu-high            ECS CPUUtilization        > 85    3 × 5m
#   ecs-prod-memory-high         ECS MemoryUtilization     > 85    3 × 5m
#   alb-prod-5xx                 HTTPCode_Target_5XX_Count  > 20    1 × 5m
#   alb-prod-latency             TargetResponseTime (p95)  > 1.5   3 × 5m
#   alb-prod-unhealthy           UnHealthyHostCount        > 0     2 × 1m
#   waf-blocked-spike            WAFV2 BlockedRequests     > 500   1 × 5m
#   jenkins-master-unreachable   EC2 StatusCheckFailed     > 0     1 × 1m
# =============================================================================

# ---- Data Sources -----------------------------------------------------------
data "aws_region" "current" {}

# The CloudWatch LoadBalancer dimension value is the LB "full name"
# (app/<name>/<id>), which is derivable from the ALB ARN
# (arn:aws:elasticloadbalancing:<region>:<acct>:loadbalancer/app/<name>/<id>).
locals {
  alb_dimension_name = "app/${element(split("/", var.alb_arn), 2)}/${element(split("/", var.alb_arn), 3)}"
  prod_service_name  = "${var.project_name}-prod"
}

# =============================================================================
# Dashboard
# =============================================================================
resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "${var.project_name}-flowharbor"

  dashboard_body = jsonencode({
    widgets = [
      # -- ECS prod: CPU + memory --------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "ECS ${local.prod_service_name} — CPU and memory"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
          dimensions = {
            ClusterName = var.cluster_name
            ServiceName = local.prod_service_name
          }
          metrics = [
            {
              id         = "ecs_cpu"
              expression = "CPUUtilization"
              label      = "CPU %"
              returnData = true
            },
            {
              id         = "ecs_memory"
              expression = "MemoryUtilization"
              label      = "Memory %"
              returnData = true
            }
          ]
        }
      },
      # -- ECS prod: task counts ---------------------------------------------
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "ECS ${local.prod_service_name} — task counts"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
          dimensions = {
            ClusterName = var.cluster_name
            ServiceName = local.prod_service_name
          }
          metrics = [
            {
              id         = "ecs_running"
              expression = "RunningTaskCount"
              label      = "Running"
              returnData = true
            },
            {
              id         = "ecs_desired"
              expression = "DesiredCount"
              label      = "Desired"
              returnData = true
            }
          ]
        }
      },
      # -- ALB: latency + 5xx -------------------------------------------------
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "ALB prod target group — latency and 5xx"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          dimensions = {
            TargetGroupFullName = var.prod_target_group_full_name
          }
          metrics = [
            {
              id         = "alb_latency"
              expression = "TargetResponseTime"
              label      = "p95 latency (s)"
              period     = 300
              stat       = "p95"
              returnData = true
            },
            {
              id         = "alb_5xx"
              expression = "HTTPCode_Target_5XX_Count"
              label      = "Target 5xx"
              period     = 300
              stat       = "Sum"
              returnData = true
            }
          ]
        }
      },
      # -- ALB: host health ---------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "ALB prod target group — host health"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Maximum"
          dimensions = {
            TargetGroupFullName = var.prod_target_group_full_name
          }
          metrics = [
            {
              id         = "alb_healthy"
              expression = "HealthyHostCount"
              label      = "Healthy hosts"
              period     = 60
              stat       = "Maximum"
              returnData = true
            },
            {
              id         = "alb_unhealthy"
              expression = "UnHealthyHostCount"
              label      = "Unhealthy hosts"
              period     = 60
              stat       = "Maximum"
              returnData = true
            }
          ]
        }
      },
      # -- WAF: blocked vs allowed --------------------------------------------
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "WAF ${var.project_name}-alb-waf — blocked vs allowed"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Sum"
          dimensions = {
            Rule   = "ALL"
            WebACL = "${var.project_name}-alb-waf"
          }
          metrics = [
            {
              id         = "waf_blocked"
              expression = "BlockedRequests"
              label      = "Blocked"
              returnData = true
            },
            {
              id         = "waf_allowed"
              expression = "AllowedRequests"
              label      = "Allowed"
              returnData = true
            }
          ]
        }
      },
      # -- Jenkins master: EC2 health -----------------------------------------
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Jenkins master — CPU and instance health"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          dimensions = {
            InstanceId = var.jenkins_master_instance_id
          }
          metrics = [
            {
              id         = "ec2_cpu"
              expression = "CPUUtilization"
              label      = "CPU %"
              period     = 300
              stat       = "Average"
              returnData = true
            },
            {
              id         = "ec2_status_check"
              expression = "StatusCheckFailed"
              label      = "Status check failures"
              period     = 60
              stat       = "Maximum"
              returnData = true
            }
          ]
        }
      }
    ]
  })
}

# =============================================================================
# Alarms
# =============================================================================

# ECS prod CPU is pinned at a 256/512 Fargate task, so sustained >85% means the
# task is starved and response times follow.
resource "aws_cloudwatch_metric_alarm" "ecs_prod_cpu_high" {
  alarm_name          = "${var.project_name}-ecs-prod-cpu-high"
  alarm_description   = "ECS ${local.prod_service_name} CPU above 85% for 15 minutes on cluster ${var.cluster_name}"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = local.prod_service_name
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-ecs-prod-cpu-high"
  }
}

# Same reasoning for memory: an OOMKill loop drains the task before it alerts.
resource "aws_cloudwatch_metric_alarm" "ecs_prod_memory_high" {
  alarm_name          = "${var.project_name}-ecs-prod-memory-high"
  alarm_description   = "ECS ${local.prod_service_name} memory above 85% for 15 minutes on cluster ${var.cluster_name}"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = local.prod_service_name
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-ecs-prod-memory-high"
  }
}

# Application errors, not infrastructure errors: 20 target 5xx in a single
# 5-minute window is a broken revision, not background noise.
resource "aws_cloudwatch_metric_alarm" "alb_prod_5xx" {
  alarm_name          = "${var.project_name}-alb-prod-5xx"
  alarm_description   = "More than 20 target 5xx responses in 5 minutes on ${var.prod_target_group_full_name} (${var.alb_arn})"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroupFullName = var.prod_target_group_full_name
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-alb-prod-5xx"
  }
}

# p95 latency catches a slow revision that is not erroring yet.
resource "aws_cloudwatch_metric_alarm" "alb_prod_latency" {
  alarm_name          = "${var.project_name}-alb-prod-latency"
  alarm_description   = "p95 target response time above 1.5s for 15 minutes on ${var.prod_target_group_full_name} (${var.alb_arn})"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1.5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroupFullName = var.prod_target_group_full_name
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-alb-prod-latency"
  }
}

# Two consecutive unhealthy checks is enough: a single blip is a deploy
# replacement, not an outage.
resource "aws_cloudwatch_metric_alarm" "alb_prod_unhealthy" {
  alarm_name          = "${var.project_name}-alb-prod-unhealthy"
  alarm_description   = "An unhealthy host registered on ${var.prod_target_group_full_name} for 2 minutes (${var.alb_arn})"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroupFullName = var.prod_target_group_full_name
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-alb-prod-unhealthy"
  }
}

# A blocked-request spike means either an attack or an over-broad WAF rule
# locking real users out — both need a human.
resource "aws_cloudwatch_metric_alarm" "waf_blocked_spike" {
  alarm_name          = "${var.project_name}-waf-blocked-spike"
  alarm_description   = "More than 500 requests blocked in 5 minutes by ${var.project_name}-alb-waf"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 500
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Rule   = "ALL"
    WebACL = "${var.project_name}-alb-waf"
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-waf-blocked-spike"
  }
}

# StatusCheckFailed > 0 means the EC2 instance itself failed its 2-minute
# status checks — Jenkins is unreachable and no release can be triggered.
resource "aws_cloudwatch_metric_alarm" "jenkins_master_unreachable" {
  alarm_name          = "${var.project_name}-jenkins-master-unreachable"
  alarm_description   = "Jenkins master ${var.jenkins_master_instance_id} failed an EC2 status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.jenkins_master_instance_id
  }

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name = "${var.project_name}-jenkins-master-unreachable"
  }
}
