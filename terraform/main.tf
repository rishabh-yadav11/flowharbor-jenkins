# =============================================================================
# main.tf — FlowHarbor Root Terraform Configuration
# =============================================================================
# This is the root module that orchestrates the entire FlowHarbor
# infrastructure. It defines providers, data sources, local values, and
# instantiates all child modules in dependency order.
#
# Infrastructure components (in instantiation order):
#   1. observability_logging — KMS CMK, encrypted log bucket, alert SNS topic
#   2. governance            — AWS Config recorder/rules + Security Hub
#   3. budget                — monthly cost limit and email actions
#   4. vpc                   — VPC with public/private subnets, NAT, IGW, VPC endpoints
#   5. security_groups       — Firewall rules for ALB, Jenkins, ECS tasks
#   6. dynamodb              — todos table (app data layer)
#   7. iam                   — IAM roles & policies for Jenkins EC2, ECS execution/task
#   8. ecr                   — Private Docker image registry
#   9. acm                   — TLS certificates (ALB + CloudFront)
#  10. jenkins_slave         — Jenkins build agent EC2 instance
#  11. jenkins_master        — Jenkins master EC2 instance
#  12. alb                   — Application Load Balancer with host-based routing
#  13. waf                   — REGIONAL ACL on the ALB + CLOUDFRONT ACL on the edge
#  14. ecs                   — Fargate cluster with dev/staging/prod services
#  15. cloudfront            — CDN distribution in front of ALB (optional, toggle with enable_cloudfront)
#  16. route53               — DNS records for all subdomains
#  17. monitoring            — CloudWatch dashboard + seven alarms on the alert topic

# ---- AWS Provider (Default) -------------------------------------------------
# The primary provider operates in the configured region (ap-south-1 by default)
# and manages most infrastructure resources.
#
# default_tags applies Project/ManagedBy/Repo to every taggable resource in
# every module that uses this provider, so cost attribution and "who owns
# this" do not depend on a resource remembering to tag itself. No module sets
# these three keys itself (each resource sets its own `Name`), so there is no
# perpetual-diff fight between here and a child module.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
}

# ---- AWS Provider (us-east-1) -----------------------------------------------
# An alias provider for us-east-1 is required because AWS Certificate Manager
# (ACM) certificates used with CloudFront MUST be provisioned in us-east-1, and
# because a CLOUDFRONT-scope WAFv2 Web ACL only exists in us-east-1. This is a
# hard requirement from AWS — CloudFront does not accept regional certificates
# from other regions, and rejects a REGIONAL ACL at web_acl_id.
#
# default_tags is repeated because provider-level defaults are per provider
# INSTANCE, not inherited: without it the CloudFront certificate and the edge
# Web ACL would be the only taggable resources in the stack with no
# Project/ManagedBy/Repo, and cost attribution would quietly miss them.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
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
# Module: Observability-Logging (issue #13)
# =============================================================================
# Central encrypted S3 log bucket + KMS CMK for ALB/CF/VPC flow logs.
module "observability_logging" {
  source       = "./modules/observability-logging"
  project_name = var.project_name
}

# GuardDuty detector (issue #13) — threat intel for EC2/ECS/IAM/S3/DNS.
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# =============================================================================
# Module: Governance
# =============================================================================
# AWS Config (drift detection) + Security Hub (finding aggregation). Needs
# only the project CMK, so it sits directly after the logging module.
module "governance" {
  source       = "./modules/governance"
  project_name = var.project_name
  kms_key_arn  = module.observability_logging.logs_kms_key_arn
}

# ---- Cost Guardrail ---------------------------------------------------------
# A demo stack nobody remembers is a bill nobody owns. The budget itself does
# not stop spend — it is the notification that reaches a human, at 80% of the
# limit, on real (not forecast) spend.
#
# Account-wide, no cost filters: a budget that silently excludes the resource
# that actually ran up the bill is worse than no budget.
resource "aws_budgets_budget" "this" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  # budget_alert_emails defaults to [], so with nothing configured the budget
  # still exists and still reports — it just has no subscriber, which is a
  # deliberate no-op rather than a hardcoded address that outlives the person
  # who set it.
  notification {
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

# =============================================================================
# Module: VPC
# =============================================================================
# Creates the foundation networking layer: VPC, subnets, routing, NAT, and
# VPC endpoints for private subnet connectivity to AWS services.
module "vpc" {
  source           = "./modules/vpc"
  aws_region       = var.aws_region
  azs              = local.azs
  vpc_cidr         = var.vpc_cidr
  project_name     = var.project_name
  logs_kms_key_arn = module.observability_logging.logs_kms_key_arn
}

# =============================================================================
# Module: Security Groups
# =============================================================================
# Defines security groups for all components: ALB (80/443 from internet),
# Jenkins Master (8080 from ALB + slave, 50000 from slave), Jenkins Slave
# (outbound-only), and ECS tasks (80 from ALB).
module "security_groups" {
  source                     = "./modules/security-groups"
  vpc_id                     = module.vpc.vpc_id
  project_name               = var.project_name
  private_subnet_cidrs       = module.vpc.private_subnet_cidrs
  alb_restrict_to_cloudfront = var.alb_restrict_to_cloudfront
}

# =============================================================================
# Module: DynamoDB
# =============================================================================
# The application's data layer. Instantiated before IAM because the ECS task
# role is scoped to this table's ARN — the whole point of least privilege here
# is that the container can reach one table and no other.
module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
  kms_key_arn  = module.observability_logging.logs_kms_key_arn
}

# =============================================================================
# Module: IAM
# =============================================================================
# Creates IAM roles and policies for:
#   - Jenkins Master EC2 (SSM parameter management, ECR read-only)
#   - Jenkins Slave EC2 (scoped SSM read, ECR push to app repo, ECS deploy,
#     sns:Publish to the alert topic)
#   - ECS execution role (pull images, write logs)
#   - ECS task role (DynamoDB access to the todos table, nothing else)
module "iam" {
  source           = "./modules/iam"
  project_name     = var.project_name
  alerts_topic_arn = module.observability_logging.alerts_topic_arn
  todo_table_arn   = module.dynamodb.table_arn
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
  iam_instance_profile = module.iam.jenkins_slave_instance_profile_name
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
  iam_instance_profile = module.iam.jenkins_master_instance_profile_name
  domain_name          = var.domain_name
  ecr_repository_url   = module.ecr.repository_url
  github_repo          = var.github_repo
  alerts_topic_arn     = module.observability_logging.alerts_topic_arn
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
  source              = "./modules/alb"
  project_name        = var.project_name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.public_subnet_ids
  security_group_id   = module.security_groups.alb_sg_id
  certificate_arn     = module.acm.alb_certificate_arn
  domain_name         = var.domain_name
  jenkins_target_ip   = module.jenkins_master.private_ip
  origin_verify_value = var.enable_cloudfront ? var.cloudfront_origin_verify_token : null
  access_logs_bucket  = module.observability_logging.bucket_id
  access_logs_prefix  = "${var.project_name}-alb"
  depends_on          = [module.jenkins_master, module.acm, module.observability_logging]
}

# =============================================================================
# Module: WAF (issue #4)
# =============================================================================
# Two ACLs, both from this module:
#   - REGIONAL on the shared ALB: Jenkins IP allowlist (office/VPN egress only,
#     default deny), /login rate limit, + AWS managed rules, plus WAF request
#     logging. Default action is allow so testing/staging/prod are unaffected.
#   - CLOUDFRONT on the distribution (only when enable_cloudfront), created in
#     us-east-1 because WAFv2 rejects a REGIONAL ACL at web_acl_id.
module "waf" {
  source                     = "./modules/waf"
  project_name               = var.project_name
  alb_arn                    = module.alb.arn
  domain_name                = var.domain_name
  jenkins_allowed_ipv4_cidrs = var.jenkins_allowed_ipv4_cidrs
  jenkins_login_rate_limit   = var.jenkins_login_rate_limit
  logs_kms_key_arn           = module.observability_logging.logs_kms_key_arn
  enable_cloudfront          = var.enable_cloudfront
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  depends_on = [module.alb]
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
  log_kms_key_id         = module.observability_logging.logs_kms_key_arn
  todo_table_name        = module.dynamodb.table_name
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
  count                 = var.enable_cloudfront ? 1 : 0
  source                = "./modules/cloudfront"
  domain_name           = var.domain_name
  alb_domain_name       = "origin.${var.domain_name}"
  certificate_arn       = module.acm.cloudfront_certificate_arn
  project_name          = var.project_name
  origin_verify_value   = var.cloudfront_origin_verify_token
  logging_bucket_domain = module.observability_logging.bucket_domain_name
  logging_prefix        = "${var.project_name}-cf"
  web_acl_id            = var.enable_cloudfront ? module.waf.cloudfront_web_acl_arn : ""
  depends_on            = [module.alb, module.acm, module.observability_logging, module.waf]
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
  enable_dnssec          = var.enable_dnssec
}

# =============================================================================
# Module: Monitoring
# =============================================================================
# Last, because it is the only module that observes the others: the dashboard
# panels and alarms need the cluster, the ALB, and the Jenkins instance to
# already exist. Every alarm publishes to the KMS-encrypted alert topic.
#
# The prod target group is addressed by NAME, because CloudWatch's
# TargetGroupFullName dimension takes a name and not an ARN — passing the ARN
# would produce a dashboard panel and two alarms that silently never match a
# metric. The name is split out of the target group ARN rather than rebuilt as
# "<project>-prod-tg", so a rename inside the ALB module can never leave this
# pointing at a group that no longer exists:
#   arn:aws:elasticloadbalancing:<region>:<acct>:targetgroup/<name>/<id>
module "monitoring" {
  source                      = "./modules/monitoring"
  project_name                = var.project_name
  alerts_topic_arn            = module.observability_logging.alerts_topic_arn
  cluster_name                = module.ecs.cluster_name
  alb_arn                     = module.alb.arn
  prod_target_group_full_name = split("/", module.alb.prod_target_group_arn)[1]
  jenkins_master_instance_id  = module.jenkins_master.instance_id
}
