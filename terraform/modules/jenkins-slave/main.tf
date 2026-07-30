# =============================================================================
# Jenkins Slave Module — main.tf
# =============================================================================
# This module provisions the Jenkins Slave (agent) EC2 instance.
#
# The Jenkins Slave runs on a t4g.medium (ARM/Graviton) instance in a
# private subnet. Its user data script (user-data/jenkins-slave.sh) performs:
#   1. Installs Java 21, Docker, AWS CLI
#   2. Retrieves the Master URL and agent secret from SSM Parameter Store
#      (polling until the Master has written them — up to 10 minutes)
#   3. Downloads the Jenkins agent.jar from the Master
#   4. Starts the JNLP agent as a systemd service
# =============================================================================

# ---- EC2 Instance -----------------------------------------------------------
# The Jenkins Slave (build agent) instance.
resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t4g.medium"  # 2 vCPU, 4 GiB RAM, ARM/Graviton
  subnet_id              = var.subnet_id # Private subnet (no public IP)
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.iam_instance_profile

  # 20 GB gp3 root volume — sufficient for Docker images and build artifacts.
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Bootstrap script with template variables (project name).
  user_data = templatefile("${path.module}/../../user-data/jenkins-slave.sh", {
    project_name = var.project_name
  })

  # Enforce IMDSv2 for security.
  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${var.project_name}-jenkins-slave"
  }
}

# ---- AMI Data Source --------------------------------------------------------
# Same Ubuntu 24.04 LTS ARM64 AMI as the Master — consistent OS across instances.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
