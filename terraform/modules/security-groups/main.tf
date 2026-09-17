# =============================================================================
# Security Groups Module — main.tf
# =============================================================================
# This module creates all security groups (firewall rules) for the FlowHarbor
# infrastructure. Each security group follows the principle of least privilege,
# allowing only the minimum required traffic.
#
# Security groups created:
#   1. alb_sg          — ALB (internet-facing): 443 in, tcp-only out (8080 master, 3000 ECS)
#   2. jenkins_master   — Jenkins controller: 8080 (ALB+slave), 50000 (slave)
#   3. jenkins_slave    — Jenkins agent: outbound-only
#   4. ecs_tasks        — Fargate containers: 3000 (ALB only)
# =============================================================================

# ---- ALB Security Group -----------------------------------------------------
# The ALB is internet-facing, so it must accept HTTPS (443) from anywhere.
# It needs unrestricted egress to forward requests to targets.
#
# Origin-bypass note (issue #3): the ideal is to allow 443 ONLY from the
# CloudFront origin-facing managed prefix list. That is incompatible with a
# single ALB that also serves direct hosts (jenkins/testing/staging), so it
# is gated behind var.alb_restrict_to_cloudfront (default false). Prod bypass
# via direct-to-ALB is blocked at L7 by the ALB prod-rule secret-header
# condition; enable strict SG mode only after splitting prod to its own ALB.
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Controls traffic to/from the Application Load Balancer"
  vpc_id      = var.vpc_id

  # Allow HTTP traffic — used ONLY for the 301 redirect listener to HTTPS
  # (no plaintext content is ever served). In strict CloudFront-only mode
  # this is scoped to the CloudFront origin-facing prefix list.
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_restrict_to_cloudfront ? null : ["0.0.0.0/0"]
    prefix_list_ids = var.alb_restrict_to_cloudfront ? [
      data.aws_ec2_managed_prefix_list.cloudfront_origin.id
    ] : null
  }

  # Allow HTTPS traffic (TLS termination at ALB). Open by default for direct
  # hosts; set alb_restrict_to_cloudfront=true to scope to CloudFront only.
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.alb_restrict_to_cloudfront ? null : ["0.0.0.0/0"]
    prefix_list_ids = var.alb_restrict_to_cloudfront ? [
      data.aws_ec2_managed_prefix_list.cloudfront_origin.id
    ] : null
  }

  # Scoped egress: TCP only to Jenkins master (8080) and ECS tasks (3000).
  # Implemented as standalone aws_security_group_rule resources below (avoids
  # the SG<->SG inline cycle: master/ecs ingress already references the ALB).
  # No inline egress here — deny-all by default except the explicit rules.

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# ALB -> Jenkins master (8080, web UI/JNLP handshake).
resource "aws_security_group_rule" "alb_egress_master" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.jenkins_master.id
  description              = "ALB to Jenkins master web UI"
}

# ALB -> ECS tasks (3000, Next.js containers).
resource "aws_security_group_rule" "alb_egress_ecs" {
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.ecs_tasks.id
  description              = "ALB to ECS tasks"
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

  # Scoped egress: HTTP/HTTPS for packages/AWS APIs, plus JNLP callback to
  # the slave (standalone rules below to avoid an inline SG<->SG cycle).
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP package downloads"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS AWS APIs and package downloads"
  }

  tags = {
    Name = "${var.project_name}-jenkins-master-sg"
  }
}

# Master -> slave callbacks (JNLP/agent communication).
resource "aws_security_group_rule" "master_egress_slave_8080" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins_master.id
  source_security_group_id = aws_security_group.jenkins_slave.id
  description              = "Master to slave agent communication"
}

resource "aws_security_group_rule" "master_egress_slave_50000" {
  type                     = "egress"
  from_port                = 50000
  to_port                  = 50000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins_master.id
  source_security_group_id = aws_security_group.jenkins_slave.id
  description              = "Master to slave JNLP"
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

  # Scoped egress: HTTP/HTTPS for Docker pulls, apt, AWS APIs, plus JNLP to
  # the master (standalone rules below to avoid an inline SG<->SG cycle).
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP package and Docker downloads"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS ECR, AWS APIs and package downloads"
  }

  tags = {
    Name = "${var.project_name}-jenkins-slave-sg"
  }
}

# Slave -> master JNLP (agent registration and web UI polling).
resource "aws_security_group_rule" "slave_egress_master_8080" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins_slave.id
  source_security_group_id = aws_security_group.jenkins_master.id
  description              = "Slave to master agent communication"
}

resource "aws_security_group_rule" "slave_egress_master_50000" {
  type                     = "egress"
  from_port                = 50000
  to_port                  = 50000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins_slave.id
  source_security_group_id = aws_security_group.jenkins_master.id
  description              = "Slave to master JNLP"
}

# ---- ECS Tasks Security Group -----------------------------------------------
# ECS Fargate tasks (Next.js containers) accept HTTP (3000) from the ALB only.
# This ensures containers are not directly accessible from the internet.
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg"
  description = "Controls traffic to/from ECS Fargate tasks"
  vpc_id      = var.vpc_id

  # Allow HTTP traffic from the ALB only (not from the internet directly).
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Scoped egress: HTTPS only (ECR via endpoints, CloudWatch Logs).
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to ECR endpoints and CloudWatch Logs"
  }

  tags = {
    Name = "${var.project_name}-ecs-tasks-sg"
  }
}
