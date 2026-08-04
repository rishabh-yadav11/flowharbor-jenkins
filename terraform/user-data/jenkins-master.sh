#!/bin/bash
# =============================================================================
# jenkins-master.sh — Jenkins Master Bootstrap Script
# =============================================================================
# This script is executed at first boot on the Jenkins Master EC2 instance.
# It performs the full setup of Jenkins, including installation, plugin
# management, node configuration, pipeline job creation, and credential setup.
#
# What this script does (in order):
#   1. Instance Metadata: Retrieves region, local IP via IMDSv2
#   2. System Packages: Installs Java 21, Docker, AWS CLI, jq
#   3. Jenkins Installation: Downloads Jenkins 2.568.1 WAR
#   4. Jenkins User: Creates system user and directories
#   5. Plugin Installation: Downloads and installs essential plugins
#   6. Systemd Service: Creates jenkins.service unit
#   7. SSM Parameters: Stores admin password and master URL in SSM
#   8. Wait for Jenkins: Polls /login until Jenkins is ready
#   9. CSRF Crumb: Fetches crumb for authenticated API calls
#  10. Slave Port: Sets JNLP agent port to 50000
#  11. Slave Node: Creates the "jenkins-slave" node via Groovy script
#  12. Agent Secret: Retrieves the JNLP secret and stores in SSM
#  13. Pipeline Jobs: Creates flowharbor-{dev,staging,prod} manual tag-based jobs
#  14. ECR Credential: Stores ECR repository URL as Jenkins credential
#
# Template variables (replaced by Terraform):
#   ${project_name}      — Project name (flowharbor)
#   ${ecr_repository_url} — ECR repository URL
#   ${domain_name}       — Root domain name (flowharbor.in)
# =============================================================================

# Exit on any error to prevent a partially-configured Jenkins master.
set -e

# Disable interactive prompts for apt.
export DEBIAN_FRONTEND=noninteractive

# ---- Instance Metadata ------------------------------------------------------
# Use IMDSv2 (token-based) to get instance metadata securely.

# Step 1: Get a session token (valid for 6 hours = 21600 seconds).
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Step 2: Define a helper function for authenticated metadata requests.
imds() { curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/$1"; }

# Step 3: Fetch the region and local IP address for configuration.
REGION=$(imds "meta-data/placement/region")
LOCAL_IP=$(imds "meta-data/local-ipv4")

# ---- System Package Installation --------------------------------------------
# Update package lists and install required packages:
#   openjdk-21-jdk-headless — Java 21 JDK (Jenkins runtime)
#   docker.io              — Docker engine for building/pushing images
#   curl, jq               — HTTP requests and JSON parsing
#   python3-pip            — Python package manager (for awscli)
apt-get update -y
apt-get install -y openjdk-21-jdk-headless docker.io curl jq python3-pip

# ---- Docker Setup -----------------------------------------------------------
# Enable and start Docker. Add the ubuntu user to the docker group so the
# Jenkins pipeline can run docker commands without password/sudo.
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# ---- AWS CLI Installation ---------------------------------------------------
# Install AWS CLI v2 via pip (the apt version may be outdated).
# --break-system-packages is needed for newer Python 3 on Ubuntu 24.04.
pip3 install awscli --break-system-packages

# ---- Reset Stale SSM Parameters ---------------------------------------------
# Clear values left over from any previous deployment so the slave never picks
# up an old agent secret or a stale "ready" marker while this master is still
# bootstrapping. These are rewritten with final values later in this script.
aws ssm put-parameter \
    --name "/${project_name}/jenkins-slave-secret" \
    --value "pending" \
    --type SecureString \
    --overwrite \
    --region "$REGION"

aws ssm put-parameter \
    --name "/${project_name}/jenkins-master-ready" \
    --value "booting" \
    --type String \
    --overwrite \
    --region "$REGION"

# ---- Jenkins WAR Download ---------------------------------------------------
# Create the directory and download the Jenkins WAR file.
# We use the latest stable release of the 2.x line (2.568.1).
mkdir -p /usr/share/jenkins
curl -fsSL https://get.jenkins.io/war-stable/2.568.1/jenkins.war -o /usr/share/jenkins/jenkins.war

# ---- Jenkins System User ----------------------------------------------------
# Create a jenkins user if it doesn't already exist.
# Set up home, log, and cache directories with proper ownership.
id -u jenkins &>/dev/null || useradd -m -d /var/lib/jenkins -s /bin/bash jenkins
mkdir -p /var/lib/jenkins /var/log/jenkins /var/cache/jenkins
chown -R jenkins:jenkins /var/lib/jenkins /var/log/jenkins /var/cache/jenkins /usr/share/jenkins

# ---- Admin Password Generation ----------------------------------------------
# Generate a random 16-byte base64-encoded password for the Jenkins admin user.
# This password will be stored in SSM Parameter Store.
ADMIN_PASS=$(openssl rand -base64 16)

# ---- Jenkins Plugin Installation --------------------------------------------
# Download the Jenkins Plugin Manager tool and use it to pre-download plugins.
# This avoids needing to install plugins via the Jenkins UI.
# The --war flag points to the Jenkins WAR so the manager can check compatibility.

curl -fsSL https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.12.13/jenkins-plugin-manager-2.12.13.jar -o /usr/share/jenkins/jenkins-plugin-manager.jar

java -jar /usr/share/jenkins/jenkins-plugin-manager.jar \
  --war /usr/share/jenkins/jenkins.war \
  --plugin-download-directory /var/lib/jenkins/plugins \
  --plugins workflow-aggregator:latest \
    git:latest \
    pipeline-aws:latest \
    docker-workflow:latest \
    cloudbees-folder:latest \
    blueocean:latest \
    credentials-binding:latest \
    configuration-as-code:latest \
    pipeline-input-step:latest \
    github:latest \
    pipeline-utility-steps:latest \
    dark-theme:latest \
    job-dsl:latest

# Fix ownership of the downloaded plugins.
chown -R jenkins:jenkins /var/lib/jenkins/plugins

# ---- Systemd Service Unit ---------------------------------------------------
# Create a systemd service file so Jenkins runs as a daemon and restarts
# automatically if it crashes. Key settings:
#   - Runs as the 'jenkins' user
#   - Disables the setup wizard (pre-configured via scripts)
#   - Allocates 1 GB max heap (-Xmx1024m)
#   - Listens on port 8080
#   - Passes the admin password as an environment variable
cat > /etc/systemd/system/jenkins.service << UNIT
[Unit]
Description=Jenkins Continuous Integration Server
After=network.target

[Service]
User=jenkins
Group=jenkins
WorkingDirectory=/var/lib/jenkins
Environment=JENKINS_HOME=/var/lib/jenkins
Environment=JENKINS_ADMIN_PASSWORD=$ADMIN_PASS
ExecStart=/usr/bin/java -Djenkins.install.runSetupWizard=false -Xmx1024m -jar /usr/share/jenkins/jenkins.war --httpPort=8080
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

# Reload systemd, enable the service to start on boot, and start it now.
systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins

# ---- Store Admin Password in SSM --------------------------------------------
# Save the generated admin password to SSM Parameter Store as a SecureString.
# The Terraform module pre-creates this parameter; we overwrite it here.
aws ssm put-parameter \
    --name "/${project_name}/jenkins-admin-password" \
    --value "$ADMIN_PASS" \
    --type SecureString \
    --overwrite \
    --region "$REGION"

# ---- Store Master URL in SSM ------------------------------------------------
# Save the Jenkins master URL (private IP + port 8080) so the slave can discover it.
aws ssm put-parameter \
    --cli-input-json "{\"Name\":\"/${project_name}/jenkins-master-url\",\"Value\":\"http://$LOCAL_IP:8080\",\"Type\":\"String\",\"Overwrite\":true}" \
    --region "$REGION"

# ---- Wait for Jenkins Readiness ---------------------------------------------
# Poll the Jenkins /login endpoint up to 60 times (10 second intervals = 10 min).
# This gives Jenkins enough time to start up with all pre-installed plugins.
for i in $(seq 1 60); do
    if curl -s -o /dev/null -w "%%{http_code}" http://localhost:8080/login --max-time 5 | grep -q 200; then
        echo "Jenkins is ready"
        break
    fi
    echo "Waiting for Jenkins... attempt $i"
    sleep 10
done

# ---- CSRF Protection Token (Crumb) ------------------------------------------
# Jenkins CSRF protection requires a "crumb" for all POST API requests.
# We fetch the crumb using the admin credentials and store it in a cookie jar.
CJAR=/tmp/jc.txt
rm -f "$CJAR"
CRUMB=$(curl -s -c "$CJAR" -b "$CJAR" -u "admin:$ADMIN_PASS" \
  'http://localhost:8080/crumbIssuer/api/json' --max-time 10 | \
  python3 -c "import sys,json;print(json.load(sys.stdin)['crumb'])")

# ---- Configure JNLP Slave Port ----------------------------------------------
# Set the Jenkins slave agent port to 50000 (standard JNLP port).
# This allows the Jenkins slave to connect via JNLP protocol.
# Uses Jenkins Groovy script console API.
curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
  -H "Jenkins-Crumb: $CRUMB" \
  -X POST 'http://localhost:8080/scriptText' \
  --data-urlencode 'script=import jenkins.model.*;def i=Jenkins.getInstance();i.setSlaveAgentPort(50000);i.save()' \
  --max-time 10

# ---- Register Slave Node ----------------------------------------------------
# Create a permanent slave node named "jenkins-slave" with:
#   - 3 executors
#   - Label "docker linux" (used by the pipeline agent directive)
#   - JNLP launcher (slave connects outbound)
#   - Always-on retention strategy
curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
  -H "Jenkins-Crumb: $CRUMB" \
  -X POST 'http://localhost:8080/scriptText' \
  --data-urlencode 'script=import jenkins.model.*;import hudson.slaves.*;def i=Jenkins.getInstance();def n=i.getNode("jenkins-slave");if(n){i.removeNode(n)};def s=new DumbSlave("jenkins-slave","/var/jenkins",null);s.setNumExecutors(3);s.setLabelString("docker linux");s.setMode(hudson.model.Node.Mode.NORMAL);s.setRetentionStrategy(new RetentionStrategy.Always());s.setLauncher(new JNLPLauncher());i.addNode(s);i.save()' \
  --max-time 10

# ---- Retrieve Slave Agent Secret --------------------------------------------
# Extract the JNLP agent secret for the newly created slave node.
# This secret is needed by the slave to authenticate with the master.
AGENT_SECRET=$(curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
  -H "Jenkins-Crumb: $CRUMB" \
  -X POST 'http://localhost:8080/scriptText' \
  --data-urlencode 'script=import jenkins.model.*;for(c in Jenkins.getInstance().computers){if(c.name=="jenkins-slave"){print(c.getJnlpMac())}}' \
  --max-time 10)

# ---- Store Slave Secret in SSM ----------------------------------------------
# Save the slave agent secret so the Jenkins Slave instance can retrieve it
# during its bootstrap process.
aws ssm put-parameter \
    --name "/${project_name}/jenkins-slave-secret" \
    --value "$AGENT_SECRET" \
    --type SecureString \
    --overwrite \
    --region "$REGION"

# ---- Create Environment Pipeline Jobs ----------------------------------------
# Create three independent Jenkins pipeline jobs (one per environment):
#   - flowharbor-dev
#   - flowharbor-staging
#   - flowharbor-prod
# Each job:
#   - Is triggered MANUALLY only (no GitHub push trigger, no SCM polling)
#   - Loads the Jenkinsfile from the main branch (Jenkinsfile always current)
#   - Takes a required GIT_TAG string parameter (the git tag to build/deploy)
#   - Derives its target environment from the job name suffix
# The app source tag checkout happens inside the Jenkinsfile itself.
for env in dev staging prod; do
  curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
    -H "Jenkins-Crumb: $CRUMB" \
    -X POST 'http://localhost:8080/scriptText' \
    --data-urlencode "script=import jenkins.model.*;import org.jenkinsci.plugins.workflow.job.WorkflowJob;import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition;import hudson.plugins.git.GitSCM;import hudson.plugins.git.BranchSpec;import hudson.plugins.git.UserRemoteConfig;import hudson.model.*;import org.jenkinsci.plugins.workflow.job.properties.*;def i=Jenkins.getInstance();def jn=\"flowharbor-$${env}\";def ex=i.getItem(jn);if(ex){ex.delete()};def j=new WorkflowJob(i,jn);j.addProperty(new ParametersDefinitionProperty(new StringParameterDefinition(\"GIT_TAG\",\"\",\"Git tag to build and deploy (e.g. 1.2.3)\")));def scm=new GitSCM([new UserRemoteConfig(\"https://github.com/rishabh-yadav11/flowharbor-jenkins-demo.git\",null,null,null)],[new BranchSpec(\"*/main\")],false,[],null,null,[]);j.setDefinition(new CpsScmFlowDefinition(scm,\"Jenkinsfile\"));i.add(j,jn);j.save();i.save();println(\"JOB_CREATED_$${env}\")" \
    --max-time 10
done

# ---- Store ECR Repository Credential ----------------------------------------
# Store the ECR repository URL as a Jenkins "string" credential so the pipeline
# can use it via `credentials('ecr-repository-url')`.
# This avoids hardcoding the URL in the Jenkinsfile.
curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
  -H "Jenkins-Crumb: $CRUMB" \
  -X POST 'http://localhost:8080/scriptText' \
  --data-urlencode 'script=import jenkins.model.*;import com.cloudbees.plugins.credentials.*;import com.cloudbees.plugins.credentials.domains.*;import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl;import hudson.util.Secret;def i=Jenkins.getInstance();def s=Domain.global();def p=CredentialsProvider.lookupStores(i).iterator().next();def id="ecr-repository-url";def ex=CredentialsProvider.lookupCredentials(StringCredentialsImpl.class,i).find({it.id==id});if(ex){p.removeCredentials(s,ex)};def c=new StringCredentialsImpl(CredentialsScope.GLOBAL,id,"ECR Repository URL",Secret.fromString("${ecr_repository_url}"));p.addCredentials(s,c);i.save();println("ECR_CRED_ADDED")' \
  --max-time 10

# ---- Signal Master Ready ----------------------------------------------------
# Tell the Jenkins Slave that the master has finished bootstrapping and that
# the master URL and agent secret in SSM are now final. The slave waits for
# this marker before downloading agent.jar and connecting via JNLP.
aws ssm put-parameter \
    --name "/${project_name}/jenkins-master-ready" \
    --value "ready" \
    --type String \
    --overwrite \
    --region "$REGION"

# ---- Completion Marker ------------------------------------------------------
echo "MASTER_SETUP_COMPLETE"
