# =============================================================================
# main.tf — FlowHarbor Root Terraform Configuration
# =============================================================================
# This is the root module that orchestrates the entire FlowHarbor
# infrastructure. It defines providers, data sources, local values, and
# instantiates all child modules in dependency order.
#
# Infrastructure components (in instantiation order):
#   1. vpc              — VPC with public/private subnets, NAT, IGW, VPC endpoints
#   2. security_groups  — Firewall rules for ALB, Jenkins, ECS tasks
#   3. iam              — IAM roles & policies for Jenkins EC2, ECS execution/task
#   4. ecr              — Private Docker image registry
#   5. acm              — TLS certificates (ALB + CloudFront)
#   6. jenkins_slave    — Jenkins build agent EC2 instance
#   7. jenkins_master   — Jenkins master EC2 instance
#   8. alb              — Application Load Balancer with host-based routing
#   9. ecs              — Fargate cluster with dev/staging/prod services
#  10. cloudfront       — CDN distribution in front of ALB (optional, toggle with enable_cloudfront)
#  11. route53          — DNS records for all subdomains
# =============================================================================

# ---- AWS Provider (Default) -------------------------------------------------
# The primary provider operates in the configured region (ap-south-1 by default)
# and manages most infrastructure resources.
provider "aws" {
  region = var.aws_region
}

# ---- AWS Provider (us-east-1) -----------------------------------------------
# An alias provider for us-east-1 is required because AWS Certificate Manager
# (ACM) certificates used with CloudFront MUST be provisioned in us-east-1.
# This is a hard requirement from AWS — CloudFront does not accept regional
# certificates from other regions.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ---- Data Sources -----------------------------------------------------------
# Fetch the list of available availability zones for the current region.
# We specifically request zones "a" and "b" to ensure consistent naming
# across accounts (some accounts have different default zone sets).
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "zone-name"
    values = ["${var.aws_region}a", "${var.aws_region}b"]
  }
}

# ---- Local Values -----------------------------------------------------------
locals {
  # Slice the AZ names list to exactly 2 zones. This provides a predictable
  # number of subnets (2 public + 2 private) regardless of how many zones
  # the account actually has available.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# =============================================================================
# Module: VPC
# =============================================================================
# Creates the foundation networking layer: VPC, subnets, routing, NAT, and
# VPC endpoints for private subnet connectivity to AWS services.
module "vpc" {
  source       = "./modules/vpc"
  aws_region   = var.aws_region
  azs          = local.azs
  vpc_cidr     = var.vpc_cidr
  project_name = var.project_name
}

# =============================================================================
# Module: Security Groups
# =============================================================================
# Defines security groups for all components: ALB (80/443 from internet),
# Jenkins Master (8080 from ALB + slave, 50000 from slave), Jenkins Slave
# (outbound-only), and ECS tasks (80 from ALB).
module "security_groups" {
  source               = "./modules/security-groups"
  vpc_id               = module.vpc.vpc_id
  project_name         = var.project_name
  private_subnet_cidrs = module.vpc.private_subnet_cidrs
}

# =============================================================================
# Module: IAM
# =============================================================================
# Creates IAM roles and policies for:
#   - Jenkins EC2 instances (SSM management, ECR access, ECS deployment, SSM params)
#   - ECS execution role (pull images, write logs)
#   - ECS task role (future-proof, currently minimal permissions)
module "iam" {
  source       = "./modules/iam"
  project_name = var.project_name
}

# =============================================================================
# Module: ECR
# =============================================================================
# Private Docker registry for the application image. Includes a lifecycle
# policy to clean up old untagged images.
module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}

# =============================================================================
# Module: ACM (TLS Certificates)
# =============================================================================
# Provisions two TLS certificates via AWS Certificate Manager:
#   1. ALB certificate — in the primary region for the load balancer HTTPS listener
#   2. CloudFront certificate — in us-east-1 (CloudFront requirement)
# Both are validated via DNS (Route53 records).
module "acm" {
  source         = "./modules/acm"
  domain_name    = var.domain_name
  hosted_zone_id = var.hosted_zone_id
  aws_region     = var.aws_region
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
}

# =============================================================================
# Module: Jenkins Slave
# =============================================================================
# The Jenkins build agent runs on an EC2 instance in a private subnet. It
# registers with the Jenkins master via JNLP and has Docker installed for
# building container images.
module "jenkins_slave" {
  source               = "./modules/jenkins-slave"
  project_name         = var.project_name
  subnet_id            = module.vpc.private_subnet_ids[1]
  security_group_id    = module.security_groups.jenkins_slave_sg_id
  iam_instance_profile = module.iam.jenkins_instance_profile_name
}

# =============================================================================
# Module: Jenkins Master
# =============================================================================
# The Jenkins master (controller) runs on an EC2 instance in a private subnet.
# Its user data script bootstraps Jenkins, installs plugins, creates the
# pipeline job, and stores credentials in SSM Parameter Store.
#
# depends_on ensures the slave is fully configured before the master bootstrap
# script runs — though the master doesn't strictly depend on the slave, this
# ordering ensures the slave SSM parameters are available.
module "jenkins_master" {
  source               = "./modules/jenkins-master"
  project_name         = var.project_name
  subnet_id            = module.vpc.private_subnet_ids[0]
  security_group_id    = module.security_groups.jenkins_master_sg_id
  iam_instance_profile = module.iam.jenkins_instance_profile_name
  domain_name          = var.domain_name
  ecr_repository_url   = module.ecr.repository_url
  depends_on           = [module.jenkins_slave]
}

# =============================================================================
# Module: ALB (Application Load Balancer)
# =============================================================================
# The ALB sits in public subnets and routes HTTPS traffic based on host headers:
#   - jenkins.flowharbor.in → Jenkins master (port 8080)
#   - testing.flowharbor.in → Dev target group
#   - staging.flowharbor.in → Staging target group
#   - flowharbor.in         → Production target group
# TLS is terminated at the ALB using the ACM certificate.
module "alb" {
  source            = "./modules/alb"
  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.security_groups.alb_sg_id
  certificate_arn   = module.acm.alb_certificate_arn
  domain_name       = var.domain_name
  jenkins_target_ip = module.jenkins_master.private_ip
  depends_on        = [module.jenkins_master, module.acm]
}

# =============================================================================
# Module: ECS (Fargate)
# =============================================================================
# The ECS cluster runs three Fargate services (dev/staging/prod), each with a
# single task running the nginx container. Each service is associated with
# its corresponding ALB target group for host-based routing.
module "ecs" {
  source                 = "./modules/ecs"
  project_name           = var.project_name
  private_subnet_ids     = module.vpc.private_subnet_ids
  ecs_task_sg_id         = module.security_groups.ecs_tasks_sg_id
  ecr_repository_url     = module.ecr.repository_url
  ecs_execution_role_arn = module.iam.ecs_execution_role_arn
  ecs_task_role_arn      = module.iam.ecs_task_role_arn
  alb_dev_tg_arn         = module.alb.dev_target_group_arn
  alb_staging_tg_arn     = module.alb.staging_target_group_arn
  alb_prod_tg_arn        = module.alb.prod_target_group_arn
  depends_on             = [module.alb, module.ecr]
}

# =============================================================================
# Module: CloudFront
# =============================================================================
# A CloudFront distribution sits in front of the ALB for the production domain.
# It provides CDN caching, DDoS protection (via AWS Shield), and SSL termination
# at the edge. Only the root domain (flowharbor.in) goes through CloudFront;
# testing and staging subdomains go directly to the ALB.
module "cloudfront" {
  count           = var.enable_cloudfront ? 1 : 0
  source          = "./modules/cloudfront"
  domain_name     = var.domain_name
  alb_domain_name = module.alb.dns_name
  certificate_arn = module.acm.cloudfront_certificate_arn
  depends_on      = [module.alb, module.acm]
}

# =============================================================================
# Module: Route53
# =============================================================================
# DNS records pointing to the ALB and CloudFront:
#   - jenkins.flowharbor.in  → ALB (A record alias)
#   - testing.flowharbor.in  → ALB (A record alias)
#   - staging.flowharbor.in  → ALB (A record alias)
#   - flowharbor.in          → CloudFront (A record alias)
module "route53" {
  source                 = "./modules/route53"
  domain_name            = var.domain_name
  hosted_zone_id         = var.hosted_zone_id
  alb_dns_name           = module.alb.dns_name
  alb_zone_id            = module.alb.zone_id
  enable_cloudfront      = var.enable_cloudfront
  cloudfront_domain_name = var.enable_cloudfront ? module.cloudfront[0].domain_name : ""
  cloudfront_zone_id     = var.enable_cloudfront ? module.cloudfront[0].hosted_zone_id : ""
}
