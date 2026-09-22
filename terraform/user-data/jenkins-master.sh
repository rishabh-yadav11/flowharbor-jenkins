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
#  13. Job DSL File:  Writes the Terraform-rendered flowharbor-jobs.groovy
#  14. Job Check:     Asserts the JCasC import created the three jobs
#  15. ECR Credential: Stores ECR repository URL as Jenkins credential
#  16. Alerts Credential: Stores the SNS alerts topic ARN as Jenkins credential
#
# Template variables (replaced by Terraform):
#   ${project_name}      — Project name (flowharbor)
#   ${ecr_repository_url} — ECR repository URL
#   ${domain_name}       — Root domain name (flowharbor.in)
#   ${github_repo}       — GitHub owner/repo (Jenkinsfile + JCasC source)
#   ${alerts_topic_arn}  — SNS topic ARN for deploy outcome notifications
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
  --plugins workflow-aggregator \
    git \
    pipeline-aws \
    docker-workflow \
    cloudbees-folder \
    blueocean \
    credentials-binding \
    configuration-as-code \
    pipeline-input-step \
    github \
    timestamper \
    pipeline-utility-steps \
    dark-theme \
    job-dsl \
    matrix-auth \
    throttle-concurrents

# NOTE (issue #16 — approval gate + deploy-churn DoS):
#   - matrix-auth: provides the Global Matrix authorization strategy configured in
#     jenkins/casc/jenkins.yaml. It is what makes `input submitter:
#     'release-managers,admin'` enforceable, and what stops an anonymous visitor
#     from reading a build log. Create the `developer` and `release-managers`
#     accounts in the Jenkins security realm (Manage Jenkins -> Users) to grant
#     them anything; the matrix entries are inert until those SIDs exist.
#   - throttle-concurrents: backs the declarative `rateLimitBuilds` / throttle
#     option in the Jenkinsfile (max 3 builds/hour) plus disableConcurrentBuilds,
#     preventing deploy-churn DoS from rapid repeated manual triggers.

# Fix ownership of the downloaded plugins.
chown -R jenkins:jenkins /var/lib/jenkins/plugins

# ---- Write Job DSL File ------------------------------------------------------
# The three pipeline jobs are defined as a Terraform-rendered Job DSL script
# (terraform/user-data/flowharbor-jobs.groovy) rather than inline Groovy here,
# so the GitHub remote is a template variable instead of a hardcoded URL. This
# block is a verbatim copy of that file; the two must stay byte-identical.
#
# The heredoc delimiter is QUOTED, so the shell performs no expansion inside the
# body — the ${github_repo} already substituted by Terraform passes through
# untouched, and the Job DSL's own Groovy is written literally.
cat > /var/lib/jenkins/flowharbor-jobs.groovy <<'FLOWHARBOR_JOBS_EOF'
// =============================================================================
// flowharbor-jobs.groovy — Job DSL source for the three FlowHarbor pipeline jobs
// =============================================================================
// Rendered by Terraform (templatefile) into /var/lib/jenkins/flowharbor-jobs.groovy
// on the Jenkins master at first boot, then executed at controller start by the
// `jobs: - file:` entry in jenkins/casc/jenkins.yaml.
//
// Every job:
//   - Is triggered MANUALLY only (no GitHub push trigger, no SCM polling)
//   - Loads the Jenkinsfile from the main branch (Jenkinsfile always current)
//   - Takes a required GIT_TAG string parameter (the git tag to build/deploy)
//   - Derives its target environment from the job name suffix
//
// REBUILD defaults to true for dev only, so staging and prod promote the exact
// image digest dev built instead of rebuilding it. The app source tag checkout
// happens inside the Jenkinsfile itself.
//
// Template variable (replaced by Terraform — the ONLY interpolation in this file):
//   ${github_repo} — owner/repo the Jenkinsfile is read from
//
// NOTE: this file is a Terraform template first and Groovy second. Any other
// dollar-brace sequence would be consumed by templatefile() before Groovy ever
// sees it, so per-environment names are built by concatenation, not GStrings.
// =============================================================================

def envs = ['dev', 'staging', 'prod']
envs.each { e ->
  pipelineJob('flowharbor-' + e) {
    description('Tag-driven build and deploy to ' + e + '. Manual trigger only.')
    logRotator { numToKeep(50) }
    parameters {
      stringParam('GIT_TAG', '', 'Git tag to build and deploy (semver, e.g. 1.2.3)')
      booleanParam('REBUILD', e == 'dev', 'Build and push a new image. When false, deploy the image already in ECR for this tag.')
      booleanParam('ALLOW_UNSIGNED_TAGS', false, 'Deploy even though the tag commit is not GPG-signed.')
    }
    definition {
      cpsScm {
        scm { git { remote { url('https://github.com/${github_repo}.git') }; branch('*/main') } }
        scriptPath('Jenkinsfile')
        lightweight(true)
      }
    }
  }
}
FLOWHARBOR_JOBS_EOF
chown jenkins:jenkins /var/lib/jenkins/flowharbor-jobs.groovy

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
Environment="CASC_JENKINS_CONFIG=https://raw.githubusercontent.com/${github_repo}/main/jenkins/casc/jenkins.yaml"
Environment="JENKINS_ADMIN_ID=admin"
Environment="JENKINS_ADMIN_PASSWORD=$${ADMIN_PASS}"
Environment="JENKINS_MASTER_URL=http://$${LOCAL_IP}:8080/"
ExecStart=/usr/bin/java -Djenkins.install.runSetupWizard=false -Xmx1024m -jar /usr/share/jenkins/jenkins.war --httpPort=8080
Restart=on-failure
RestartSec=10

# ---- Hardening --------------------------------------------------------------
# The admin password IS passed as a systemd environment variable, because JCasC
# needs it to create the local 'admin' user. It never touches a file in this
# repo: $${ADMIN_PASS} is expanded by the shell into the unit file at boot, and
# the unit file is written as root with 0644 perms. ${github_repo} is a
# Terraform template variable; $${ADMIN_PASS}/$${LOCAL_IP} are shell variables.
# These directives limit the blast radius if Jenkins is ever compromised.
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/var/lib/jenkins /var/log/jenkins /var/cache/jenkins
NoNewPrivileges=true

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

# ---- Verify Delivery Jobs (created by the JCasC import) ----------------------
# The three jobs (flowharbor-dev / -staging / -prod) are no longer built from
# inline Groovy here. They are defined in /var/lib/jenkins/flowharbor-jobs.groovy
# (written above, before the service starts) and created at boot by the
# `jobs: - file:` entry in jenkins/casc/jenkins.yaml.
# Benefits: the jobs are real policy-as-code that survives controller rebuilds,
# and the GitHub remote is a Terraform variable rather than a hardcoded URL.
#
# Assert all three exist. A missing job means the JCasC import failed — and a
# failed JCasC import aborts the controller boot entirely, so reaching this
# point at all means the strategy, security realm, and Job DSL were all applied.
# This is a hard boot failure (exit 1), never a warning: a half-configured
# controller must never signal "ready".
for env_name in dev staging prod; do
  # `curl -f` turns any HTTP error into a non-zero exit, so no curl write-out
  # format is needed. A printf-style format containing a literal percent-brace
  # would be parsed by Terraform's templatefile() as a template directive and
  # fail the whole render, so this check avoids one deliberately.
  if curl -sf -o /dev/null -u "admin:$ADMIN_PASS" \
    "http://localhost:8080/job/flowharbor-$env_name/api/json" --max-time 10; then
    echo "Verified job flowharbor-$env_name"
  else
    echo "ERROR: flowharbor-$env_name was not created by the JCasC import" >&2
    exit 1
  fi
done

# ---- Store ECR Repository Credential ----------------------------------------
# Store the ECR repository URL as a Jenkins "string" credential so the pipeline
# can use it via `credentials('ecr-repository-url')`.
# This avoids hardcoding the URL in the Jenkinsfile.
# NOTE (issue #20): ECR URL is non-secret routing data; GLOBAL scope is required
# for pipeline `credentials()` lookup. Defense-in-depth lives in the Jenkinsfile
# `ecrRepoName()` allowlist (fail-closed on poisoned/malformed values) — see also
# `ecr_repository_name` output for a parse-free alternative.
# Fail fast if Terraform rendered a malformed URL so it never becomes a credential.
if ! printf '%s' "${ecr_repository_url}" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/[a-z0-9]+([._/-][a-z0-9]+)*$'; then
  echo "ERROR: malformed ecr_repository_url: ${ecr_repository_url}" >&2
  exit 1
fi
curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
  -H "Jenkins-Crumb: $CRUMB" \
  -X POST 'http://localhost:8080/scriptText' \
  --data-urlencode 'script=import jenkins.model.*;import com.cloudbees.plugins.credentials.*;import com.cloudbees.plugins.credentials.domains.*;import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl;import hudson.util.Secret;def i=Jenkins.getInstance();def s=Domain.global();def p=CredentialsProvider.lookupStores(i).iterator().next();def id="ecr-repository-url";def ex=CredentialsProvider.lookupCredentials(StringCredentialsImpl.class,i).find({it.id==id});if(ex){p.removeCredentials(s,ex)};def c=new StringCredentialsImpl(CredentialsScope.GLOBAL,id,"ECR Repository URL",Secret.fromString("${ecr_repository_url}"));p.addCredentials(s,c);i.save();println("ECR_CRED_ADDED")' \
  --max-time 10

# ---- Store Alerts Topic Credential ------------------------------------------
# Store the KMS-encrypted SNS topic ARN used to publish deploy outcomes. The
# pipeline reads it via `credentials('alerts-topic-arn')`. The matching
# `sns:Publish` grant scoped to this one topic is on the slave role (iam module).
curl -s -u "admin:$ADMIN_PASS" -c "$CJAR" -b "$CJAR" \
  -H "Jenkins-Crumb: $CRUMB" \
  -X POST 'http://localhost:8080/scriptText' \
  --data-urlencode 'script=import jenkins.model.*;import com.cloudbees.plugins.credentials.*;import com.cloudbees.plugins.credentials.domains.*;import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl;import hudson.util.Secret;def i=Jenkins.getInstance();def s=Domain.global();def p=CredentialsProvider.lookupStores(i).iterator().next();def id="alerts-topic-arn";def ex=CredentialsProvider.lookupCredentials(StringCredentialsImpl.class,i).find({it.id==id});if(ex){p.removeCredentials(s,ex)};def c=new StringCredentialsImpl(CredentialsScope.GLOBAL,id,"SNS Alerts Topic ARN",Secret.fromString("${alerts_topic_arn}"));p.addCredentials(s,c);i.save();println("ALERTS_CRED_ADDED")' \
  --max-time 10

# ---- RBAC / Approval Gate (issue #16) -----------------------------------------
# RBAC is no longer a comment. It is applied by Configuration-as-Code, which
# the controller imports at boot (CASC_JENKINS_CONFIG, set in the systemd unit):
#   - the 'developer' role (Overall/Read, Job/Read, Job/Build) and the
#     'release-managers' role (which adds Job/Input/Proceed) are defined in
#     jenkins/casc/jenkins.yaml.
# Job/Input/Proceed is what makes the Jenkinsfile prod Approval stage
# (`input submitter: 'release-managers,admin'`) actually enforce anything.

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
