# =============================================================================
# ECS Module — main.tf
# =============================================================================
# This module creates the ECS Fargate infrastructure for running the
# FlowHarbor application containers.
#
# Resources created:
#   1. ECS Cluster — with Container Insights enabled
#   2. Task Definitions (x3) — dev, staging, prod (Fargate, ARM64)
#   3. ECS Services (x3) — one per environment, tied to ALB target groups
#   4. CloudWatch Log Groups (x3) — one per environment (7-day retention)
#
# The container image and environment variables are set at task definition
# creation time. The Jenkins pipeline updates these by registering new
# revisions with CI/CD metadata (build number, git info, etc.).
# =============================================================================

# ---- ECS Cluster ------------------------------------------------------------
# The Fargate cluster that hosts all three environment services.
# Container Insights provides detailed metrics (CPU, memory, network).
resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster" # flowharbor-cluster

  setting {
    name  = "containerInsights"
    value = "enabled" # Enable detailed performance monitoring
  }

  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# ---- Local Values -----------------------------------------------------------
# Base container definition shared across all three task definitions.
# Individual environments merge their specific values on top of this base.
locals {
  container_base = {
    name      = "app" # Container name within the task
    image     = "${var.ecr_repository_url}:latest"
    essential = true # If this container fails, the task stops
    portMappings = [
      {
        containerPort = 80 # Next.js listens on port 80
        protocol      = "tcp"
      }
    ]
    logConfiguration = {
      logDriver = "awslogs" # Send logs to CloudWatch Logs
      options = {
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "app" # Prefix for log streams
      }
    }
  }
}

# =============================================================================
# Task Definitions
# =============================================================================
# Each environment gets its own task definition so the Jenkins pipeline can
# independently update each one with CI/CD metadata.
#
# All tasks use Fargate launch type (serverless) with ARM64 architecture for
# cost efficiency. CPU/Memory: 256/512 is the smallest Fargate config.

# ---- Dev Task Definition ----------------------------------------------------
resource "aws_ecs_task_definition" "dev" {
  family                   = "${var.project_name}-dev" # flowharbor-dev
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"                   # Each task gets its own ENI
  cpu                      = "256"                      # 0.25 vCPU
  memory                   = "512"                      # 512 MB RAM
  execution_role_arn       = var.ecs_execution_role_arn # For ECR pull + logs
  task_role_arn            = var.ecs_task_role_arn      # For container AWS API calls

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton for cost efficiency
  }

  # Merge base config with dev-specific values.
  container_definitions = jsonencode([
    merge(local.container_base, {
      image = "${var.ecr_repository_url}:latest"
      logConfiguration = merge(local.container_base.logConfiguration, {
        options = merge(local.container_base.logConfiguration.options, {
          "awslogs-group" = "/ecs/${var.project_name}-dev"
        })
      })
      # Default environment values — Jenkins pipeline overrides these at deploy time.
      environment = [
        { name = "ENV", value = "dev" },
        { name = "VERSION", value = "1.0.0" },
        { name = "BUILD_NUMBER", value = "0" },
        { name = "GIT_COMMIT", value = "none" },
        { name = "GIT_BRANCH", value = "none" },
        { name = "GIT_AUTHOR", value = "none" },
        { name = "TIMESTAMP", value = "none" },
        { name = "PIPELINE_URL", value = "none" }
      ]
    })
  ])

  tags = {
    Name = "${var.project_name}-dev"
  }
}

# ---- Staging Task Definition ------------------------------------------------
resource "aws_ecs_task_definition" "staging" {
  family                   = "${var.project_name}-staging"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    merge(local.container_base, {
      image = "${var.ecr_repository_url}:latest"
      logConfiguration = merge(local.container_base.logConfiguration, {
        options = merge(local.container_base.logConfiguration.options, {
          "awslogs-group" = "/ecs/${var.project_name}-staging"
        })
      })
      environment = [
        { name = "ENV", value = "staging" },
        { name = "VERSION", value = "1.0.0" },
        { name = "BUILD_NUMBER", value = "0" },
        { name = "GIT_COMMIT", value = "none" },
        { name = "GIT_BRANCH", value = "none" },
        { name = "GIT_AUTHOR", value = "none" },
        { name = "TIMESTAMP", value = "none" },
        { name = "PIPELINE_URL", value = "none" }
      ]
    })
  ])

  tags = {
    Name = "${var.project_name}-staging"
  }
}

# ---- Production Task Definition ---------------------------------------------
resource "aws_ecs_task_definition" "prod" {
  family                   = "${var.project_name}-prod"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    merge(local.container_base, {
      image = "${var.ecr_repository_url}:latest"
      logConfiguration = merge(local.container_base.logConfiguration, {
        options = merge(local.container_base.logConfiguration.options, {
          "awslogs-group" = "/ecs/${var.project_name}-prod"
        })
      })
      environment = [
        { name = "ENV", value = "prod" },
        { name = "VERSION", value = "1.0.0" },
        { name = "BUILD_NUMBER", value = "0" },
        { name = "GIT_COMMIT", value = "none" },
        { name = "GIT_BRANCH", value = "none" },
        { name = "GIT_AUTHOR", value = "none" },
        { name = "TIMESTAMP", value = "none" },
        { name = "PIPELINE_URL", value = "none" }
      ]
    })
  ])

  tags = {
    Name = "${var.project_name}-prod"
  }
}

# =============================================================================
# ECS Services
# =============================================================================
# Each service runs a single task (desired_count = 1) with Fargate launch type.
# They are placed in private subnets and are fronted by the ALB.

# ---- Dev Service ------------------------------------------------------------
resource "aws_ecs_service" "dev" {
  name            = "${var.project_name}-dev"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.dev.arn
  desired_count   = 1 # Single task for the demo
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids # Private subnets only
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false # No public IP needed
  }

  # Register with the dev ALB target group.
  load_balancer {
    target_group_arn = var.alb_dev_tg_arn
    container_name   = "app"
    container_port   = 80
  }
}

# ---- Staging Service --------------------------------------------------------
resource "aws_ecs_service" "staging" {
  name            = "${var.project_name}-staging"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.staging.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.alb_staging_tg_arn
    container_name   = "app"
    container_port   = 80
  }
}

# ---- Production Service -----------------------------------------------------
resource "aws_ecs_service" "prod" {
  name            = "${var.project_name}-prod"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.prod.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.alb_prod_tg_arn
    container_name   = "app"
    container_port   = 80
  }
}

# =============================================================================
# CloudWatch Log Groups
# =============================================================================
# Each environment has its own log group for container logs.
# Retention is set to 7 days to balance debugging needs with storage costs.

resource "aws_cloudwatch_log_group" "dev" {
  name              = "/ecs/${var.project_name}-dev"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "staging" {
  name              = "/ecs/${var.project_name}-staging"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "prod" {
  name              = "/ecs/${var.project_name}-prod"
  retention_in_days = 7
}

# ---- Data Sources -----------------------------------------------------------
# Fetch the current region for constructing CloudWatch log group ARNs.
data "aws_region" "current" {}
