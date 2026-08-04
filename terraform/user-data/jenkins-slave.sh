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

# ---- Master Ready Marker Polling --------------------------------------------
# The Jenkins master writes /${project_name}/jenkins-master-ready = "ready" only
# AFTER it has fully bootstrapped (plugins installed, slave node created, agent
# secret stored in SSM). The slave must wait for BOTH:
#   - the marker set to "ready", AND
#   - a real (non-placeholder) agent secret in SSM
# This prevents the slave from acting on a stale "ready" marker or a stale
# secret left behind by a previous master that has since been replaced.
#
# We poll up to 40 times (15-second intervals = 10 minutes max wait).
for i in $(seq 1 40); do
    READY=$(aws ssm get-parameter \
        --name "/${project_name}/jenkins-master-ready" \
        --query "Parameter.Value" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "")

    SECRET=$(aws ssm get-parameter \
        --name "/${project_name}/jenkins-slave-secret" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "")

    if [ "$READY" = "ready" ] && [ -n "$SECRET" ] && [ "$SECRET" != "None" ] && [ "$SECRET" != "pending" ]; then
        echo "Jenkins master is ready"
        AGENT_SECRET="$SECRET"
        break
    fi

    echo "Waiting for Jenkins master to finish bootstrapping... attempt $i"
    sleep 15
done

# ---- Validate Master Readiness ----------------------------------------------
# If the marker was never set to "ready" (with a real secret) within the polling
# window, exit with an error so the failure is visible in the cloud-init logs.
if [ -z "$AGENT_SECRET" ] || [ "$AGENT_SECRET" = "None" ] || [ "$AGENT_SECRET" = "pending" ]; then
    echo "Timed out waiting for Jenkins master to become ready"
    exit 1
fi

# ---- Download Agent Jar -----------------------------------------------------
# Download the Jenkins agent.jar from the master's JNLP endpoint and verify it
# is a valid ZIP/JAR before starting the agent. The master may still be warming
# up, so retry with backoff and re-read the master URL on every attempt (it is
# rewritten by the master when its private IP changes across recreations).
for i in $(seq 1 30); do
    MASTER_URL=$(aws ssm get-parameter \
        --name "/${project_name}/jenkins-master-url" \
        --query "Parameter.Value" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "")

    curl -sL -o /home/ubuntu/jenkins-agent/agent.jar "$MASTER_URL/jnlpJars/agent.jar" --max-time 30
    if [ -s /home/ubuntu/jenkins-agent/agent.jar ] && python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1])" /home/ubuntu/jenkins-agent/agent.jar 2>/dev/null; then
        echo "agent.jar downloaded successfully"
        break
    fi
    echo "Retrying agent.jar download... attempt $i"
    sleep 15
done

# ---- Agent Start Wrapper ----------------------------------------------------
# Create a wrapper script that re-reads the master URL and agent secret from
# SSM on every invocation. The systemd unit restarts this on failure, so if the
# master is ever recreated the agent automatically re-connects with the fresh
# secret instead of being stuck with a stale one baked into the unit file.
cat > /home/ubuntu/jenkins-agent/start-agent.sh << 'WRAPPER'
#!/bin/bash
export PATH=$PATH:/usr/local/bin

IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/placement/region")

MASTER_URL=$(aws ssm get-parameter \
    --name "/${project_name}/jenkins-master-url" \
    --query "Parameter.Value" \
    --output text \
    --region "$REGION")

AGENT_SECRET=$(aws ssm get-parameter \
    --name "/${project_name}/jenkins-slave-secret" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$REGION")

if [ -z "$MASTER_URL" ] || [ "$MASTER_URL" = "None" ] || \
   [ -z "$AGENT_SECRET" ] || [ "$AGENT_SECRET" = "None" ] || [ "$AGENT_SECRET" = "pending" ]; then
    echo "SSM parameters not ready yet, will retry"
    exit 1
fi

# Ensure a valid agent.jar exists before starting. If the master was recreated
# or the initial download happened while the master was still coming up, the
# jar may be missing or stale — re-download it from the CURRENT master URL.
if [ ! -s /home/ubuntu/jenkins-agent/agent.jar ] || ! python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1])" /home/ubuntu/jenkins-agent/agent.jar 2>/dev/null; then
    echo "agent.jar missing or invalid, downloading from $MASTER_URL"
    rm -f /home/ubuntu/jenkins-agent/agent.jar
    curl -sL -o /home/ubuntu/jenkins-agent/agent.jar "$MASTER_URL/jnlpJars/agent.jar" --max-time 30
    if [ ! -s /home/ubuntu/jenkins-agent/agent.jar ] || ! python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1])" /home/ubuntu/jenkins-agent/agent.jar 2>/dev/null; then
        echo "agent.jar download failed, will retry"
        exit 1
    fi
fi

exec /usr/bin/java -jar /home/ubuntu/jenkins-agent/agent.jar \
  -url "$MASTER_URL" \
  -secret "$AGENT_SECRET" \
  -name jenkins-slave \
  -workDir /var/jenkins
WRAPPER
chmod +x /home/ubuntu/jenkins-agent/start-agent.sh
chown -R ubuntu:ubuntu /home/ubuntu/jenkins-agent

# ---- Systemd Service Unit ---------------------------------------------------
# Create a systemd service for the Jenkins agent so it:
#   - Runs as the ubuntu user (not root)
#   - Starts automatically on system boot
#   - Restarts on failure (Restart=always)
#   - Re-reads the master URL and secret from SSM on every restart
cat > /etc/systemd/system/jenkins-agent.service << SERVICE
[Unit]
Description=Jenkins Agent Slave
After=network.target docker.service

[Service]
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/jenkins-agent
ExecStart=/home/ubuntu/jenkins-agent/start-agent.sh
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
