# =============================================================================
# IAM Module — main.tf
# =============================================================================
# This module creates all IAM roles, policies, and instance profiles required
# by the FlowHarbor infrastructure.
#
# Roles created:
#   1. jenkins_master  — Assumed by the Jenkins Master EC2 instance
#   2. jenkins_slave   — Assumed by the Jenkins Slave EC2 instance (build agent)
#   3. ecs_execution   — Assumed by ECS agent to pull images and write logs
#   4. ecs_task        — Assumed by the application container (minimal perms)
#
# Policies attached:
#   - AmazonSSMManagedInstanceCore   (SSM management for EC2, both roles)
#   - Custom (master): SSM parameter read/write on /flowharbor/*
#   - Custom (master): ECR read-only scoped to the app repository
#   - Custom (master): EC2 describe (diagnostics)
#   - Custom (slave): SSM GetParameter on master-url / slave-secret / master-ready only
#   - Custom (slave): ECR push/pull scoped to the app repository only
#   - Custom (slave): ECS deploy (register task def, update service) + PassRole
#     conditioned on iam:PassedToService = ecs-tasks.amazonaws.com
#   - Custom (slave): EC2 describe (for build metadata)
#   - AmazonECSTaskExecutionRolePolicy (ECS execution base)
#   - Custom: ECR auth + log writing (for ECS execution)
# =============================================================================

# =============================================================================
# Jenkins Master Role (issue #5)
# =============================================================================
# The Master bootstraps Jenkins, writes SSM params (admin password, master URL,
# slave secret, ready marker) and stores the ECR URL credential. It never builds
# images and never deploys to ECS, so it gets NO ECR-push, NO ECS deploy and NO
# PassRole permissions. A compromise of the master role alone cannot push images
# or roll ECS services.

resource "aws_iam_role" "jenkins_master" {
  name = "${var.project_name}-jenkins-master-role"

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
    Name = "${var.project_name}-jenkins-master-role"
  }
}

# Allow the master instance to use AWS Systems Manager (Session Manager, etc.)
resource "aws_iam_role_policy_attachment" "jenkins_master_ssm" {
  role       = aws_iam_role.jenkins_master.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Master manages all Jenkins SSM parameters (writes admin password, master URL,
# slave secret, ready marker during bootstrap).
resource "aws_iam_role_policy" "jenkins_master_ssm_param" {
  name = "${var.project_name}-master-ssm-param"
  role = aws_iam_role.jenkins_master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter"
        ]
        # Master owns the full project parameter path.
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
      }
    ]
  })
}

# Master only READS from ECR (e.g. verifying images). No push permissions.
resource "aws_iam_role_policy" "jenkins_master_ecr_read" {
  name = "${var.project_name}-master-ecr-read"
  role = aws_iam_role.jenkins_master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*" # GetAuthorizationToken has no resource-level restrictions
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-app"
      }
    ]
  })
}

# Read-only EC2 metadata for diagnostics.
resource "aws_iam_role_policy" "jenkins_master_ec2_describe" {
  name = "${var.project_name}-master-ec2-describe"
  role = aws_iam_role.jenkins_master.id

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

# Instance profile for the Jenkins Master instance.
resource "aws_iam_instance_profile" "jenkins_master" {
  name = "${var.project_name}-jenkins-master-instance-profile"
  role = aws_iam_role.jenkins_master.name
}

# =============================================================================
# Jenkins Slave Role (issue #5)
# =============================================================================
# The Slave runs the CI/CD pipeline (build, ECR push, ECS deploy). It gets the
# minimum set required for that job:
#   - SSM GetParameter ONLY on the three non-secret/bootstrap params it needs
#     (master URL, slave secret, ready marker). Notably NO access to
#     /flowharbor/jenkins-admin-password and NO PutParameter at all, so stolen
#     slave creds cannot overwrite the admin password or poison bootstrap state.
#   - ECR push/pull scoped to the single flowharbor-app repository (replaces the
#     former AmazonEC2ContainerRegistryPowerUser which covered ALL repositories).
#   - ECS RegisterTaskDefinition/UpdateService scoped to this project's
#     families/services/cluster, with PassRole locked to the two ECS roles AND
#     conditioned on iam:PassedToService = ecs-tasks.amazonaws.com.

resource "aws_iam_role" "jenkins_slave" {
  name = "${var.project_name}-jenkins-slave-role"

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
    Name = "${var.project_name}-jenkins-slave-role"
  }
}

# Allow the slave instance to use AWS Systems Manager (Session Manager, etc.)
resource "aws_iam_role_policy_attachment" "jenkins_slave_ssm" {
  role       = aws_iam_role.jenkins_slave.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Slave bootstrap (user-data/jenkins-slave.sh) polls exactly these three params:
#   /flowharbor/jenkins-master-url, /flowharbor/jenkins-slave-secret,
#   /flowharbor/jenkins-master-ready. Read-only, no PutParameter, no admin password.
resource "aws_iam_role_policy" "jenkins_slave_ssm_param" {
  name = "${var.project_name}-slave-ssm-read"
  role = aws_iam_role.jenkins_slave.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = [
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/jenkins-master-url",
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/jenkins-slave-secret",
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/jenkins-master-ready"
        ]
      }
    ]
  })
}

# Least-privilege ECR push/pull scoped to the single app repository.
# Replaces AmazonEC2ContainerRegistryPowerUser (all repos, incl. image deletion).
resource "aws_iam_role_policy" "jenkins_slave_ecr" {
  name = "${var.project_name}-slave-ecr-push"
  role = aws_iam_role.jenkins_slave.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*" # GetAuthorizationToken has no resource-level restrictions
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-app"
      }
    ]
  })
}

# Custom policy: deploy new ECS task definitions and update services.
# PassRole is locked to the exact ECS roles AND requires the call to pass the
# role to the ECS tasks service, so slave creds cannot be reused to hand the
# roles to an attacker's EC2/Lambda/etc.
# All actions are scoped to THIS project's resources (cluster, services,
# task-definition families) rather than "*".
resource "aws_iam_role_policy" "jenkins_slave_ecs" {
  name = "${var.project_name}-slave-ecs-deploy"
  role = aws_iam_role.jenkins_slave.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition"
        ]
        Resource = "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:task-definition/${var.project_name}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices"
        ]
        Resource = "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:service/${var.project_name}-cluster/${var.project_name}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:ListServices",
          "ecs:DescribeClusters"
        ]
        Resource = "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:cluster/${var.project_name}-cluster"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        # Only allow passing the specific ECS roles created by this module,
        # and only when handing them to the ECS tasks service.
        Resource = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Custom policy: allow describing EC2 instances (used for build metadata).
resource "aws_iam_role_policy" "jenkins_slave_ec2_describe" {
  name = "${var.project_name}-slave-ec2-describe"
  role = aws_iam_role.jenkins_slave.id

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

# Instance profile that attaches the Jenkins Slave role to the slave instance.
resource "aws_iam_instance_profile" "jenkins_slave" {
  name = "${var.project_name}-jenkins-slave-instance-profile"
  role = aws_iam_role.jenkins_slave.name
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
  # Confused-deputy protection: the principal must be a task launched in OUR
  # account and OUR project's cluster (prevents cross-account role stealing).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          StringLike = {
            "aws:SourceArn" = "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:cluster/${var.project_name}-cluster"
          }
        }
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
# Image operations are scoped to the app repository; log operations are
# scoped to this project's ECS log groups.
resource "aws_iam_role_policy" "ecs_execution_ecr" {
  name = "${var.project_name}-ecs-execution-ecr"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*" # GetAuthorizationToken has no resource-level restrictions
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-app"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}-*:*"
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

  # Trust policy: allow ECS tasks service to assume this role.
  # Confused-deputy protection scoped to our account and project cluster.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          StringLike = {
            "aws:SourceArn" = "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:cluster/${var.project_name}-cluster"
          }
        }
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
