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
#
# Containers run as an unprivileged user on port 3000 (see app/Dockerfile).
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
# NOTE: bootstrap image only — Jenkins promote() replaces it with repo@digest.
locals {
  container_base = {
    name                   = "app" # Container name within the task
    image                  = "${var.ecr_repository_url}:${var.initial_image_tag}"
    essential              = true   # If this container fails, the task stops
    user                   = "node" # Run as unprivileged node user (matches Dockerfile USER)
    readonlyRootFilesystem = true   # Immutable root FS; writable paths via mountPoints
    privileged             = false  # Never grant extended host privileges
    linuxParameters = {
      initProcessEnabled = true # tini-style init for zombie reaping
    }
    healthCheck = {
      command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
    mountPoints = [
      {
        sourceVolume  = "tmp"
        containerPath = "/tmp"
        readOnly      = false
      },
      {
        sourceVolume  = "public"
        containerPath = "/app/public"
        readOnly      = false
      }
    ]
    portMappings = [
      {
        containerPort = 3000 # Next.js listens on 3000 (non-root container port)
        protocol      = "tcp"
      }
    ]
    logConfiguration = {
      logDriver = "awslogs" # Send logs to CloudWatch Logs
      options = {
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "app" # Prefix for log streams
      }
    }
  }
}

# ---- SSM Parameters for container secrets (issue #15) -------------------------
# GIT_AUTHOR and PIPELINE_URL are per-environment SecureStrings consumed via
# the ECS `secrets` block (never plaintext `environment`). Values are managed
# at deploy time by Jenkins promote() (put-parameter --overwrite); Terraform
# owns the parameter skeleton only. lifecycle ignore_changes prevents TF from
# reverting Jenkins-updated values on every apply.
resource "aws_ssm_parameter" "git_author" {
  for_each = toset(["dev", "staging", "prod"])
  name     = "${var.ssm_parameter_prefix}/${each.key}/GIT_AUTHOR"
  type     = "SecureString"
  value    = "none"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${var.project_name}-${each.key}-git-author"
  }
}

resource "aws_ssm_parameter" "pipeline_url" {
  for_each = toset(["dev", "staging", "prod"])
  name     = "${var.ssm_parameter_prefix}/${each.key}/PIPELINE_URL"
  type     = "SecureString"
  value    = "none"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${var.project_name}-${each.key}-pipeline-url"
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
  # NOTE: GIT_AUTHOR/PIPELINE_URL are delivered via `secrets` (SSM SecureString),
  # never plaintext `environment` (issue #15).
  container_definitions = jsonencode([
    merge(local.container_base, {
      image = "${var.ecr_repository_url}:${var.initial_image_tag}"
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
        { name = "TIMESTAMP", value = "none" }
      ]
      secrets = [
        { name = "GIT_AUTHOR", valueFrom = aws_ssm_parameter.git_author["dev"].arn },
        { name = "PIPELINE_URL", valueFrom = aws_ssm_parameter.pipeline_url["dev"].arn }
      ]
    })
  ])

  volume {
    name = "tmp"
  }

  volume {
    name = "public"
  }

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
      image = "${var.ecr_repository_url}:${var.initial_image_tag}"
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
        { name = "TIMESTAMP", value = "none" }
      ]
      secrets = [
        { name = "GIT_AUTHOR", valueFrom = aws_ssm_parameter.git_author["staging"].arn },
        { name = "PIPELINE_URL", valueFrom = aws_ssm_parameter.pipeline_url["staging"].arn }
      ]
    })
  ])

  volume {
    name = "tmp"
  }

  volume {
    name = "public"
  }

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
      image = "${var.ecr_repository_url}:${var.initial_image_tag}"
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
        { name = "TIMESTAMP", value = "none" }
      ]
      secrets = [
        { name = "GIT_AUTHOR", valueFrom = aws_ssm_parameter.git_author["prod"].arn },
        { name = "PIPELINE_URL", valueFrom = aws_ssm_parameter.pipeline_url["prod"].arn }
      ]
    })
  ])

  volume {
    name = "tmp"
  }

  volume {
    name = "public"
  }

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
  name                              = "${var.project_name}-dev"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.dev.arn
  desired_count                     = var.desired_count["dev"]
  launch_type                       = "FARGATE"
  enable_execute_command            = var.enable_execute_command
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = 60

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids # Private subnets only
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false # No public IP needed
  }

  # Register with the dev ALB target group.
  load_balancer {
    target_group_arn = var.alb_dev_tg_arn
    container_name   = "app"
    container_port   = 3000
  }
}

# ---- Staging Service --------------------------------------------------------
resource "aws_ecs_service" "staging" {
  name                              = "${var.project_name}-staging"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.staging.arn
  desired_count                     = var.desired_count["staging"]
  launch_type                       = "FARGATE"
  enable_execute_command            = var.enable_execute_command
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = 60

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.alb_staging_tg_arn
    container_name   = "app"
    container_port   = 3000
  }
}

# ---- Production Service -----------------------------------------------------
resource "aws_ecs_service" "prod" {
  name                              = "${var.project_name}-prod"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.prod.arn
  desired_count                     = var.desired_count["prod"]
  launch_type                       = "FARGATE"
  enable_execute_command            = var.enable_execute_command
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = 60

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.alb_prod_tg_arn
    container_name   = "app"
    container_port   = 3000
  }
}

# =============================================================================
# CloudWatch Log Groups
# =============================================================================
# Each environment has its own log group for container logs.
# Retention: 30 days for dev/staging, 90 days for prod (issue #15).
# Encrypted with the observability-logging CMK when var.log_kms_key_id is set.

resource "aws_cloudwatch_log_group" "dev" {
  name              = "/ecs/${var.project_name}-dev"
  retention_in_days = 30
  kms_key_id        = var.log_kms_key_id
}

resource "aws_cloudwatch_log_group" "staging" {
  name              = "/ecs/${var.project_name}-staging"
  retention_in_days = 30
  kms_key_id        = var.log_kms_key_id
}

resource "aws_cloudwatch_log_group" "prod" {
  name              = "/ecs/${var.project_name}-prod"
  retention_in_days = 90
  kms_key_id        = var.log_kms_key_id
}

# ---- Data Sources -----------------------------------------------------------
# Fetch the current region for constructing CloudWatch log group ARNs.
data "aws_region" "current" {}
