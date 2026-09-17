# =============================================================================
# VPC Module — main.tf
# =============================================================================
# This module creates the foundational networking layer for FlowHarbor.
#
# Resources created:
#   1. VPC — with DNS hostnames and support enabled
#   2. Internet Gateway — for public subnet internet access
#   3. NAT Gateway (Elastic IP) — for private subnet outbound traffic
#   4. Public Subnets (x2) — for the ALB and NAT Gateway
#   5. Private Subnets (x2) — for Jenkins instances and ECS tasks
#   6. Route Tables & Associations — public (IGW) and private (NAT)
#   7. VPC Endpoints — S3 (Gateway), ECR API/DKR, SSM, EC2, Logs (Interface)
#
# Why VPC Endpoints?
#   Since Jenkins and ECS tasks run in private subnets (no public IPs), they
#   normally need a NAT Gateway to reach AWS APIs. VPC endpoints allow them
#   to communicate with AWS services privately without going through the NAT,
#   reducing cost and improving security.
# =============================================================================

# ---- VPC --------------------------------------------------------------------
# The main VPC with a /16 CIDR block. DNS hostnames and DNS support are
# enabled so that resources get DNS names and can resolve Route53 private
# hosted zones.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # Assigns DNS hostnames to instances
  enable_dns_support   = true # Enables DNS resolution within the VPC

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ---- Internet Gateway -------------------------------------------------------
# The IGW provides internet access for public subnet resources (ALB).
# It's a horizontally scaled, redundant, and highly available gateway.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ---- NAT Gateways (per AZ) ----------------------------------------------------
# One EIP + NAT Gateway per AZ so a single-AZ failure does not blackhole all
# private subnets, and to avoid cross-AZ data charges.
#
# STATE MIGRATION: this used to be a single aws_eip.nat / aws_nat_gateway.this
# in public[0] with one shared private route table. After pulling this change,
# run once (before apply):
#   terraform state mv module.vpc.aws_eip.nat module.vpc.aws_eip.nat[0]
#   terraform state mv module.vpc.aws_nat_gateway.this module.vpc.aws_nat_gateway.this[0]
#   terraform state mv module.vpc.aws_route_table.private module.vpc.aws_route_table.private[0]
# (moved blocks below cover the same rename on fresh Terraform >= 1.1 runs.)
moved {
  from = aws_eip.nat
  to   = aws_eip.nat[0]
}

moved {
  from = aws_nat_gateway.this
  to   = aws_nat_gateway.this[0]
}

moved {
  from = aws_route_table.private
  to   = aws_route_table.private[0]
}

resource "aws_eip" "nat" {
  count  = length(var.azs) # One per AZ
  domain = "vpc"           # Allocate in the VPC domain (not EC2-Classic)

  tags = {
    Name = "${var.project_name}-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "this" {
  count         = length(var.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id # Same-AZ public subnet

  tags = {
    Name = "${var.project_name}-nat-gw-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---- Public Subnets ---------------------------------------------------------
# Two public subnets across two AZs. These host the ALB and NAT Gateway.
# map_public_ip_on_launch is false because the ALB doesn't need public IPs
# (it gets its own DNS name), and nothing else is launched directly in
# public subnets.
resource "aws_subnet" "public" {
  count                   = length(var.azs) # One per AZ
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24, 10.0.1.0/24
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
    Tier = "public"
  }
}

# ---- Private Subnets --------------------------------------------------------
# Two private subnets across two AZs. These host Jenkins Master, Jenkins Slave,
# and ECS Fargate tasks. No public IPs — all outbound traffic goes through
# the NAT Gateway or VPC endpoints.
resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10) # 10.0.10.0/24, 10.0.11.0/24
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    Tier = "private"
  }
}

# ---- Public Route Table -----------------------------------------------------
# Routes all internet-bound traffic (0.0.0.0/0) through the Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Associate each public subnet with the public route table.
resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- Private Route Tables (per AZ) --------------------------------------------
# One route table per AZ, each pointing at the same-AZ NAT Gateway.
resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = {
    Name = "${var.project_name}-private-rt-${count.index + 1}"
  }
}

# Associate each private subnet with its same-AZ private route table.
resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# =============================================================================
# VPC Endpoints
# =============================================================================
# Gateway Endpoints are free and route traffic through the VPC route table.
# Interface Endpoints cost money but allow private subnet resources to reach
# AWS services without a NAT Gateway.

# ---- S3 Gateway Endpoint ----------------------------------------------------
# Free endpoint that allows private subnet instances to access S3 via the
# private route table. No additional cost, no security group needed.
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.this.id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = aws_route_table.private[*].id

  # Least-privilege: ECR layer downloads + artifact/log bucket access only.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-s3-vpce"
  }
}

# ---- ECR API Endpoint -------------------------------------------------------
# Interface endpoint for ECR API calls (listing images, authentication).
# Required by Jenkins slave to push/pull images from ECR.
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true # Use private DNS names (api.ecr.*)

  # Least-privilege: ECR read/auth API calls only.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetAuthorizationToken",
        "ecr:GetDownloadUrlForLayer",
        "ecr:ListImages"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-ecr-api-vpce"
  }
}

# ---- ECR DKR Endpoint -------------------------------------------------------
# Interface endpoint for ECR Docker registry API (docker pull/push).
# Required by Jenkins slave and ECS tasks to transfer container images.
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Least-privilege: image layer downloads (+ S3 backing store for layers).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "s3:GetObject"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-ecr-dkr-vpce"
  }
}

# ---- SSM Messages Endpoint --------------------------------------------------
# Interface endpoint for AWS Systems Manager (SSM) to manage EC2 instances
# via Session Manager without requiring SSH or public IPs.
resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Least-privilege: Session Manager data/control channel only.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-ssmmessages-vpce"
  }
}

# ---- EC2 Messages Endpoint --------------------------------------------------
# Interface endpoint for EC2-to-SSM messaging (heartbeat, commands).
resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Least-privilege: SSM agent messaging only.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-ec2messages-vpce"
  }
}

# ---- EC2 Endpoint -----------------------------------------------------------
# Interface endpoint for EC2 API calls (describe instances, etc.).
resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Least-privilege: read-only EC2 metadata used for diagnostics.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeTags"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-ec2-vpce"
  }
}

# ---- CloudWatch Logs Endpoint -----------------------------------------------
# Interface endpoint for CloudWatch Logs. ECS tasks use this to send
# container logs without going through the NAT Gateway.
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Least-privilege: container/SSM log delivery only.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-logs-vpce"
  }
}

# ---- SSM Endpoint -----------------------------------------------------------
# Interface endpoint for the SSM Parameter Store / control plane. Without it,
# GetParameter/PutParameter calls from private subnets traverse the NAT.
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Least-privilege: parameter read/write + instance info for managed nodes.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "ssm:DescribeParameters",
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:PutParameter",
        "ssm:UpdateInstanceInformation"
      ]
      Resource = "*"
    }]
  })

  tags = {
    Name = "${var.project_name}-ssm-vpce"
  }
}

# ---- VPC Endpoints Security Group -------------------------------------------
# Allows HTTPS (443) inbound from the VPC CIDR and scoped HTTPS-only egress
# back into the VPC. All interface endpoints share this security group.
resource "aws_security_group" "vpce" {
  name        = "${var.project_name}-vpce"
  description = "Security group for VPC Interface Endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # Only allow traffic from within VPC
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp" # HTTPS responses to VPC clients only
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-vpce-sg"
  }
}

# =============================================================================
# VPC Flow Logs (issue #13) — detective control for L3/L4 lateral movement.
# =============================================================================
resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/vpc/${var.project_name}/flow"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_iam_role" "flow_log" {
  name = "${var.project_name}-vpc-flow-log-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.project_name}-vpc-flow-log-policy"
  role = aws_iam_role.flow_log.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow.arn
  iam_role_arn         = aws_iam_role.flow_log.arn
}
