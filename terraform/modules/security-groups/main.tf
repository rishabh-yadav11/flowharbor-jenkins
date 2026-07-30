# =============================================================================
# Security Groups Module — main.tf
# =============================================================================
# This module creates all security groups (firewall rules) for the FlowHarbor
# infrastructure. Each security group follows the principle of least privilege,
# allowing only the minimum required traffic.
#
# Security groups created:
#   1. alb_sg          — ALB (internet-facing): 443 in, all out
#   2. jenkins_master   — Jenkins controller: 8080 (ALB+slave), 50000 (slave)
#   3. jenkins_slave    — Jenkins agent: outbound-only
#   4. ecs_tasks        — Fargate containers: 80 (ALB only)
# =============================================================================

# ---- ALB Security Group -----------------------------------------------------
# The ALB is internet-facing, so it must accept HTTPS (443) from anywhere.
# It needs unrestricted egress to forward requests to targets.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Controls traffic to/from the Application Load Balancer"
  vpc_id      = var.vpc_id

  # Allow HTTPS traffic from the internet (TLS termination at ALB).
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic to reach target groups and AWS services.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# ---- Jenkins Master Security Group ------------------------------------------
# The Jenkins master accepts:
#   - HTTP (8080) from the ALB (for the web UI via HTTPS→ALB→8080)
#   - HTTP (8080) from the Jenkins slave (for JNLP agent-master communication)
#   - TCP (50000) from the Jenkins slave (JNLP agent port)
resource "aws_security_group" "jenkins_master" {
  name        = "${var.project_name}-jenkins-master-sg"
  description = "Controls traffic to/from the Jenkins Master instance"
  vpc_id      = var.vpc_id

  # Allow Jenkins web UI access from the ALB (via HTTPS → ALB → private IP).
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Allow Jenkins web UI and agent communication from the slave.
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins_slave.id]
  }

  # Allow JNLP agent connection from the slave on port 50000.
  ingress {
    from_port       = 50000
    to_port         = 50000
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins_slave.id]
  }

  # Unrestricted egress for package downloads, AWS API calls, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-jenkins-master-sg"
  }
}

# ---- Jenkins Slave Security Group -------------------------------------------
# The slave initiates all connections (to master via JNLP, to ECR, etc.),
# so it only needs outbound access. No inbound rules required.
resource "aws_security_group" "jenkins_slave" {
  name        = "${var.project_name}-jenkins-slave-sg"
  description = "Controls traffic to/from the Jenkins Slave instance"
  vpc_id      = var.vpc_id

  # No ingress rules — the slave is outbound-only. It connects to the master
  # by initiating outbound JNLP connections.

  # Full outbound access for Docker pulls, apt, AWS APIs, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-jenkins-slave-sg"
  }
}

# ---- ECS Tasks Security Group -----------------------------------------------
# ECS Fargate tasks (nginx containers) accept HTTP (80) from the ALB only.
# This ensures containers are not directly accessible from the internet.
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg"
  description = "Controls traffic to/from ECS Fargate tasks"
  vpc_id      = var.vpc_id

  # Allow HTTP traffic from the ALB only (not from the internet directly).
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Outbound access for logs, pulling images, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-tasks-sg"
  }
}
