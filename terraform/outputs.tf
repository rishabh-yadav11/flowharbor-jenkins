# =============================================================================
# outputs.tf — FlowHarbor Root Module Outputs
# =============================================================================
# These outputs provide useful information after `terraform apply` completes.
# They surface URLs, DNS names, resource identifiers, and helper commands
# that the operator needs to access and manage the deployed infrastructure.
# =============================================================================

# ---- Application URLs -------------------------------------------------------
# The main entry points for each environment.

output "jenkins_url" {
  description = "Jenkins UI URL — the web interface for the CI/CD server"
  value       = "https://jenkins.${var.domain_name}"
}

output "testing_url" {
  description = "Testing (dev) environment URL — automatically deployed on every build"
  value       = "https://testing.${var.domain_name}"
}

output "staging_url" {
  description = "Staging environment URL — requires manual approval to deploy"
  value       = "https://staging.${var.domain_name}"
}

output "production_url" {
  description = "Production environment URL — final deployment target with manual approval gate"
  value       = "https://${var.domain_name}"
}

# ---- Infrastructure DNS Names -----------------------------------------------
# Raw DNS names for the ALB and CloudFront, useful for debugging or CNAME config.

output "alb_dns_name" {
  description = "ALB DNS name — the load balancer's AWS-assigned hostname"
  value       = module.alb.dns_name
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name — the CDN's AWS-assigned hostname (null when CloudFront is disabled)"
  value       = var.enable_cloudfront ? module.cloudfront[0].domain_name : null
}

# ---- Container Registry -----------------------------------------------------

output "ecr_repository_url" {
  description = "ECR repository URL — used by the CI/CD pipeline to push/pull Docker images"
  value       = module.ecr.repository_url
}

# ---- Admin Commands ---------------------------------------------------------
# Helpful CLI commands for retrieving sensitive credentials.

output "jenkins_admin_password_command" {
  description = "AWS CLI command to retrieve the Jenkins admin password from SSM Parameter Store (requires SSM permissions)"
  value       = "aws ssm get-parameter --name /${var.project_name}/jenkins-admin-password --with-decryption --query Parameter.Value --output text"
}

# ---- Instance Identifiers ---------------------------------------------------
# EC2 instance IDs for direct AWS console access or SSM Session Manager.

output "jenkins_master_instance_id" {
  description = "Jenkins Master EC2 instance ID — for SSM Session Manager or AWS console access"
  value       = module.jenkins_master.instance_id
}

output "jenkins_slave_instance_id" {
  description = "Jenkins Slave EC2 instance ID — for SSM Session Manager or AWS console access"
  value       = module.jenkins_slave.instance_id
}
