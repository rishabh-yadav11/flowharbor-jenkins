# =============================================================================
# Jenkins Master Module — main.tf
# =============================================================================
# This module provisions the Jenkins Master (controller) EC2 instance and
# related SSM parameters.
#
# The Jenkins Master runs on a t4g.medium (ARM/Graviton) instance in a
# private subnet. Its user data script (user-data/jenkins-master.sh) performs
# full bootstrapping:
#   1. Installs Java 21, Docker, AWS CLI
#   2. Downloads and configures Jenkins 2.568.1
#   3. Installs plugins (git, pipeline, blueocean, etc.)
#   4. Creates admin password and stores in SSM Parameter Store
#   5. Configures JNLP slave agent port (50000)
#   6. Registers the Jenkins Slave node
#   7. Creates the pipeline jobs (flowharbor-dev, staging, prod)
#   8. Stores ECR repository URL as a Jenkins credential
# =============================================================================

# ---- EC2 Instance -----------------------------------------------------------
# The Jenkins Master instance. It uses Graviton (ARM64) for cost efficiency.
resource "aws_instance" "this" {
  # Ubuntu 24.04 LTS ARM64 AMI (fetched via data source below).
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t4g.medium"  # 2 vCPU, 4 GiB RAM, ARM/Graviton
  subnet_id              = var.subnet_id # Private subnet (no public IP)
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.iam_instance_profile

  # 30 GB gp3 root volume — enough for Jenkins, plugins, Docker images, etc.
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # Bootstrap script with template variables (ECR URL, domain, project name).
  user_data = templatefile("${path.module}/../../user-data/jenkins-master.sh", {
    ecr_repository_url = var.ecr_repository_url
    domain_name        = var.domain_name
    project_name       = var.project_name
  })

  # Recreate the instance whenever the bootstrap script changes so fixes to
  # user-data are applied automatically on the next terraform apply.
  user_data_replace_on_change = true

  # Enforce IMDSv2 (token-based metadata access) for security best practice.
  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${var.project_name}-jenkins-master"
  }
}

# ---- AMI Data Source --------------------------------------------------------
# Find the latest Ubuntu 24.04 LTS (Noble) ARM64 AMI from Canonical.
# Owner 099720109477 is Canonical's official AWS account ID.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"] # ARM/Graviton for cost efficiency
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---- SSM Parameters ---------------------------------------------------------
# Pre-create SSM parameters that the user data script will also populate.
# The initial value is "pending" and the lifecycle policy ignores future
# changes (so terraform apply won't overwrite the Jenkins-generated value).

# Store the initial (placeholder) admin password. The bootstrap script will
# overwrite this with the actual generated password.
resource "aws_ssm_parameter" "jenkins_admin_password" {
  name  = "/${var.project_name}/jenkins-admin-password"
  type  = "SecureString"
  value = "pending"

  # Ignore changes to the value so the bootstrap script's generated password
  # is preserved across terraform apply runs.
  lifecycle {
    ignore_changes = [value]
  }
}

# Store the Jenkins master URL (private IP + port 8080) for the slave to discover.
resource "aws_ssm_parameter" "jenkins_master_url" {
  name  = "/${var.project_name}/jenkins-master-url"
  type  = "String"
  value = "http://${aws_instance.this.private_ip}:8080"

  lifecycle {
    ignore_changes = [value]
  }
}
