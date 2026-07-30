# =============================================================================
# ALB Module — main.tf
# =============================================================================
# This module creates an Application Load Balancer (ALB) that routes HTTPS
# traffic to backend services based on the Host header.
#
# Architecture:
#   - Internet-facing ALB in public subnets
#   - TLS termination using ACM certificate
#   - Host-based routing to 4 target groups:
#     - jenkins.flowharbor.in  → Jenkins Master (port 8080)
#     - testing.flowharbor.in  → Dev Fargate service (port 80)
#     - staging.flowharbor.in  → Staging Fargate service (port 80)
#     - flowharbor.in          → Prod Fargate service (port 80)
#   - Default 404 response for unhandled hostnames
# =============================================================================

# ---- ALB --------------------------------------------------------------------
# The main load balancer resource. It's internet-facing because it serves
# public traffic, but it only listens on HTTPS (TLS terminates here).
resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  internal           = false         # Internet-facing (public)
  load_balancer_type = "application" # Layer 7 HTTP/HTTPS
  security_groups    = [var.security_group_id]
  subnets            = var.subnet_ids # Public subnets across 2 AZs

  # Disabled for demo purposes (enabling would prevent terraform destroy).
  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# ---- Target Groups ----------------------------------------------------------
# Each target group represents a backend service. ALB forwards requests to
# the target group that matches the request's Host header.

# Jenkins Master target group — routes to the EC2 instance's private IP on 8080.
resource "aws_lb_target_group" "jenkins" {
  name        = "${var.project_name}-jenkins-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Target by IP address (for EC2 instance)

  health_check {
    path                = "/login" # Jenkins login page
    port                = 8080
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name = "${var.project_name}-jenkins-tg"
  }
}

# Dev target group — routes to the dev Fargate service on port 80.
resource "aws_lb_target_group" "dev" {
  name        = "${var.project_name}-dev-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Target by IP address (for Fargate tasks)

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name = "${var.project_name}-dev-tg"
  }
}

# Staging target group — routes to the staging Fargate service.
resource "aws_lb_target_group" "staging" {
  name        = "${var.project_name}-staging-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name = "${var.project_name}-staging-tg"
  }
}

# Production target group — routes to the prod Fargate service.
resource "aws_lb_target_group" "prod" {
  name        = "${var.project_name}-prod-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name = "${var.project_name}-prod-tg"
  }
}

# ---- Target Group Attachments -----------------------------------------------
# Register the Jenkins Master's private IP as a target in the Jenkins TG.
# The Fargate services register themselves via ECS service load_balancer blocks.

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = var.jenkins_target_ip # Private IP of Jenkins Master
  port             = 8080
}

# ---- HTTPS Listener ---------------------------------------------------------
# The main listener on port 443. TLS is terminated here using the ACM cert.
# Default action returns 404 for unhandled hostnames — this acts as a catch-all
# that doesn't match any listener rule.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08" # Modern but compatible TLS policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404 Not Found"
      status_code  = "404"
    }
  }
}

# ---- Listener Rules (Host-Based Routing) ------------------------------------
# Each rule matches a specific Host header and forwards to the corresponding TG.
# Priority values are spaced to allow inserting new rules without renumbering.

# jenkins.flowharbor.in → Jenkins Master
resource "aws_lb_listener_rule" "jenkins" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }

  condition {
    host_header {
      values = ["jenkins.${var.domain_name}"]
    }
  }
}

# testing.flowharbor.in → Dev
resource "aws_lb_listener_rule" "dev" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dev.arn
  }

  condition {
    host_header {
      values = ["testing.${var.domain_name}"]
    }
  }
}

# staging.flowharbor.in → Staging
resource "aws_lb_listener_rule" "staging" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staging.arn
  }

  condition {
    host_header {
      values = ["staging.${var.domain_name}"]
    }
  }
}

# flowharbor.in → Production
resource "aws_lb_listener_rule" "prod" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 40

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod.arn
  }

  condition {
    host_header {
      values = [var.domain_name] # Root domain (no subdomain)
    }
  }
}
