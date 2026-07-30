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

# ---- NAT Gateway ------------------------------------------------------------
# An Elastic IP (EIP) is allocated for the NAT Gateway.
# The NAT Gateway lives in the first public subnet and provides outbound
# internet access for private subnet resources (to pull Docker images,
# apt packages, AWS APIs via non-endpoint services, etc.).
resource "aws_eip" "nat" {
  domain = "vpc" # Allocate in the VPC domain (not EC2-Classic)

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Deploy in the first public subnet

  tags = {
    Name = "${var.project_name}-nat-gw"
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

# ---- Private Route Table ----------------------------------------------------
# Routes all internet-bound traffic through the NAT Gateway.
# This is more expensive than IGW but necessary for private subnets.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Associate each private subnet with the private route table.
resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
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
  route_table_ids = [aws_route_table.private.id]

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

  tags = {
    Name = "${var.project_name}-logs-vpce"
  }
}

# ---- VPC Endpoints Security Group -------------------------------------------
# Allows HTTPS (443) inbound from the VPC CIDR and all outbound traffic.
# All interface endpoints share this security group.
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-vpce-sg"
  }
}
