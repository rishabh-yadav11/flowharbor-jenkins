#!/bin/bash
# =============================================================================
# jenkins-slave.sh — Jenkins Slave Bootstrap Script
# =============================================================================
# This script is executed at first boot on the Jenkins Slave EC2 instance.
# It connects to the Jenkins Master via JNLP and registers as a build agent.
#
# What this script does (in order):
#   1. System Packages: Installs Java 21, Docker, AWS CLI
#   2. Docker Setup: Enables Docker and adds ubuntu user
#   3. Agent Directory: Creates workspace directory
#   4. SSM Polling: Retrieves master URL and agent secret from SSM
#      (polls up to 10 minutes — waits for master to finish bootstrapping)
#   5. Agent Download: Downloads agent.jar from the master
#   6. Systemd Service: Creates jenkins-agent.service unit
#   7. Start Agent: Starts the JNLP agent connection
#
# Template variables (replaced by Terraform):
#   ${project_name} — Project name (flowharbor)
# =============================================================================

# Disable interactive prompts for apt.
export DEBIAN_FRONTEND=noninteractive

# ---- Instance Metadata ------------------------------------------------------
# Use IMDSv2 to discover the current region.
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
imds() { curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/$1"; }
REGION=$(imds "meta-data/placement/region")

# ---- System Package Installation --------------------------------------------
# Install the same packages as the master:
#   openjdk-21-jdk-headless — Java 21 for running the agent.jar
#   docker.io              — Docker engine for building images on slave
#   curl, jq               — HTTP requests and JSON parsing
#   python3-pip            — Python package manager (for awscli)
# stderr is redirected and only last 3 lines shown for cleaner logs.
apt-get update -y
apt-get install -y openjdk-21-jdk-headless docker.io curl jq python3-pip 2>&1 | tail -3

# ---- Docker Setup -----------------------------------------------------------
# Enable and start Docker. The slave needs Docker to build and push images
# during the pipeline's Build and Push to ECR stages.
systemctl enable docker 2>/dev/null
systemctl start docker 2>/dev/null
usermod -aG docker ubuntu 2>/dev/null

# ---- AWS CLI Installation ---------------------------------------------------
export PATH=$PATH:/usr/local/bin
pip3 install awscli --break-system-packages 2>&1 | tail -3

# ---- Agent Directory Creation -----------------------------------------------
# Create the Jenkins agent workspace directory and the working directory.
# The agent.jar and build artifacts will live here.
mkdir -p /home/ubuntu/jenkins-agent /var/jenkins
chown -R ubuntu:ubuntu /home/ubuntu/jenkins-agent /var/jenkins

# ---- SSM Parameter Polling --------------------------------------------------
# The Jenkins Master creates SSM parameters during its bootstrap. The slave
# must wait for these to be available before it can connect.
#
# We poll up to 30 times (20-second intervals = 10 minutes max wait).
# This accounts for the time the master takes to install Jenkins, plugins,
# and create the slave node configuration.
for i in $(seq 1 30); do
    # Fetch the master URL (plaintext parameter).
    MASTER_URL=$(aws ssm get-parameter \
        --name "/${project_name}/jenkins-master-url" \
        --query "Parameter.Value" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "")

    # Fetch the slave secret (encrypted SecureString parameter).
    AGENT_SECRET=$(aws ssm get-parameter \
        --name "/${project_name}/jenkins-slave-secret" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "")

    # If both values are non-empty and not "None", break out of the loop.
    if [ -n "$MASTER_URL" ] && [ "$MASTER_URL" != "None" ] && [ -n "$AGENT_SECRET" ] && [ "$AGENT_SECRET" != "None" ]; then
        break
    fi

    echo "Waiting for Jenkins master SSM params... attempt $i"
    sleep 20
done

# ---- Validate SSM Parameters ------------------------------------------------
# If the parameters weren't found within the polling window, exit with an error.
if [ -z "$MASTER_URL" ] || [ "$MASTER_URL" = "None" ]; then
    echo "Failed to discover Jenkins master URL"
    exit 1
fi

# ---- Download Agent Jar -----------------------------------------------------
# Download the Jenkins agent.jar from the master's JNLP endpoint.
# This JAR file is the JNLP agent that connects to the master.
curl -sL -o /home/ubuntu/jenkins-agent/agent.jar "$MASTER_URL/jnlpJars/agent.jar" --max-time 30

# ---- Systemd Service Unit ---------------------------------------------------
# Create a systemd service for the Jenkins agent so it:
#   - Runs as the ubuntu user (not root)
#   - Starts automatically on system boot
#   - Restarts on failure (Restart=always)
#   - Connects to the master using the retrieved URL and secret
#   - Uses /var/jenkins as the working directory
cat > /etc/systemd/system/jenkins-agent.service << SERVICE
[Unit]
Description=Jenkins Agent Slave
After=network.target docker.service

[Service]
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/jenkins-agent
ExecStart=/usr/bin/java -jar /home/ubuntu/jenkins-agent/agent.jar \
  -url $MASTER_URL \
  -secret $AGENT_SECRET \
  -name jenkins-slave \
  -workDir /var/jenkins
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

# Reload systemd, enable the service to start on boot, and start it now.
systemctl daemon-reload
systemctl enable jenkins-agent
systemctl start jenkins-agent

# ---- Completion Marker ------------------------------------------------------
echo "SLAVE_SETUP_COMPLETE"
