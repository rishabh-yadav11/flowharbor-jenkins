# =============================================================================
# IAM Module — main.tf
# =============================================================================
# This module creates all IAM roles, policies, and instance profiles required
# by the FlowHarbor infrastructure.
#
# Roles created:
#   1. jenkins_ec2      — Assumed by EC2 instances (Master + Slave)
#   2. ecs_execution     — Assumed by ECS agent to pull images and write logs
#   3. ecs_task          — Assumed by the application container (minimal perms)
#
# Policies attached:
#   - AmazonSSMManagedInstanceCore   (SSM management for EC2)
#   - AmazonEC2ContainerRegistryPowerUser (ECR push/pull for Jenkins)
#   - Custom: SSM parameter read/write
#   - Custom: ECS deploy permissions (register task def, update service)
#   - Custom: EC2 describe (for build metadata)
#   - AmazonECSTaskExecutionRolePolicy (ECS execution base)
#   - Custom: ECR auth + log writing (for ECS execution)
# =============================================================================

# =============================================================================
# Jenkins EC2 Role
# =============================================================================
# This role is assumed by both Jenkins Master and Slave EC2 instances via an
# instance profile. It grants permissions for SSM management, ECR access, ECS
# deployment, and SSM parameter store operations.

resource "aws_iam_role" "jenkins_ec2" {
  name = "${var.project_name}-jenkins-ec2-role"

  # Trust policy: allow EC2 service to assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-jenkins-ec2-role"
  }
}

# Allow EC2 instances to use AWS Systems Manager (Session Manager, patching, etc.)
resource "aws_iam_role_policy_attachment" "jenkins_ec2_ssm" {
  role       = aws_iam_role.jenkins_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow Jenkins to push/pull images from ECR (build and deploy stages).
resource "aws_iam_role_policy_attachment" "jenkins_ec2_ecr" {
  role       = aws_iam_role.jenkins_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Custom policy: read/write SSM parameters for Jenkins configuration
# (admin password, master URL, slave secret — all prefixed with /flowharbor/).
resource "aws_iam_role_policy" "jenkins_ec2_ssm_param" {
  name = "${var.project_name}-ssm-param"
  role = aws_iam_role.jenkins_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter"
        ]
        # Restrict to parameters under the project path, e.g., /flowharbor/*
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
      }
    ]
  })
}

# Custom policy: deploy new ECS task definitions and update services.
# Also allows iam:PassRole for the ECS execution and task roles so Jenkins
# can register task definitions that reference those roles.
resource "aws_iam_role_policy" "jenkins_ec2_ecs" {
  name = "${var.project_name}-ecs-deploy"
  role = aws_iam_role.jenkins_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:ListServices",
          "ecs:DescribeClusters"
        ]
        # Allow on any ECS resource in this account (scoped by cluster/service in code)
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        # Only allow passing the specific ECS roles created by this module
        Resource = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
      }
    ]
  })
}

# Custom policy: allow describing EC2 instances (used for build metadata).
resource "aws_iam_role_policy" "jenkins_ec2_ec2_describe" {
  name = "${var.project_name}-ec2-describe"
  role = aws_iam_role.jenkins_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance profile that attaches the Jenkins EC2 role to EC2 instances.
resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-instance-profile"
  role = aws_iam_role.jenkins_ec2.name
}

# =============================================================================
# ECS Execution Role
# =============================================================================
# This role is assumed by the ECS agent (not the container itself). It has
# permissions to pull container images from ECR and write logs to CloudWatch.
# The ECS agent uses these permissions regardless of what the container does.

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project_name}-ecs-execution-role"

  # Trust policy: allow ECS tasks service to assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-execution-role"
  }
}

# Attach the AWS-managed ECS task execution policy (base permissions).
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom policy: add ECR auth and log stream creation permissions.
# The managed policy doesn't include ECR auth, so we add it here.
resource "aws_iam_role_policy" "ecs_execution_ecr" {
  name = "${var.project_name}-ecs-execution-ecr"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*" # ECR auth token doesn't support resource-level restrictions
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*" # Scoped by log group ARN in practice
      }
    ]
  })
}

# =============================================================================
# ECS Task Role
# =============================================================================
# This role is assumed by the container itself at runtime. It's currently
# minimal (the nginx container doesn't need AWS API access), but is available
# for future use if the application needs to call AWS APIs.

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-task-role"
  }
}

# ---- Data Sources -----------------------------------------------------------
# Fetch the current AWS account ID for constructing resource ARNs in policies.
data "aws_caller_identity" "current" {}
