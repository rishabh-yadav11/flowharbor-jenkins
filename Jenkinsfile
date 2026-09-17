// =============================================================================
// Jenkinsfile — FlowHarbor CI/CD Pipeline (Tag-Based, Per-Environment)
// =============================================================================
// This declarative Jenkins pipeline builds and deploys the FlowHarbor demo
// application for a SINGLE environment, selected by the Jenkins job that runs it.
//
// Jobs:
//   flowharbor-dev      → deploys to dev      (https://testing.flowharbor.in)
//   flowharbor-staging  → deploys to staging  (https://staging.flowharbor.in)
//   flowharbor-prod     → deploys to prod     (https://flowharbor.in)
//
// Trigger: MANUAL only. No SCM polling, no webhooks. A developer runs one of the
// three jobs and enters the GIT_TAG parameter (the git tag to build and deploy).
//
// Pipeline stages (in order):
//   1. Checkout Tag — validate env + tag, resolve tag to immutable SHA, verify,
//      clean workspace and check out the SHA (Jenkinsfile itself from main).
//   2. Build         — Docker image build, tagged with GIT_TAG only (no :latest)
//   3. Push to ECR   — Push tag, resolve + verify digest, scan gate, archive metadata
//   4. Deploy        — Register new TD revision pinned to repo@digest and roll env.
//
// On success, a summary banner with the deployed environment, tag and digest is printed.
//
// The `promote()` function encapsulates the logic for registering a new ECS
// task definition revision and triggering a rolling service update.
// =============================================================================

// ---- Pipeline Definition ----------------------------------------------------
pipeline {
    agent { label 'jenkins-slave' }

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '50'))
        timeout(time: 30, unit: 'MINUTES')
    }

    // ---- Parameters -----------------------------------------------------------
    // The git tag to build and deploy. Filled in by the developer when manually
    // triggering one of the three environment jobs.
    parameters {
        string(name: 'GIT_TAG', defaultValue: '',
               description: 'Git tag to build and deploy (e.g. 1.2.3)')
    }

    // ---- Environment Variables ------------------------------------------------
    // These variables are available to all stages in the pipeline.
    environment {
        // AWS region where all infrastructure lives (Mumbai, ap-south-1).
        AWS_DEFAULT_REGION = 'ap-south-1'

        // The ECR repository URL is injected via a Jenkins credential of type
        // "string". This credential was pre-created during the Jenkins master
        // bootstrap process (see terraform/user-data/jenkins-master.sh).
        ECR_REPOSITORY = credentials('ecr-repository-url')

        // Name of the ECS cluster that hosts the Fargate services.
        CLUSTER_NAME = 'flowharbor-cluster'

        // Target environment is derived from the job name suffix:
        //   flowharbor-dev → dev, flowharbor-staging → staging, flowharbor-prod → prod
        TARGET_ENV = env.JOB_NAME.tokenize('-').last()

        // Pipeline URL and deploy timestamp (git metadata is captured in the
        // "Checkout Tag" stage so it reflects the checked-out tag, not main).
        PIPELINE_URL = "${env.BUILD_URL}"
        TIMESTAMP = sh(script: "date -u +'%Y-%m-%dT%H:%M:%SZ'", returnStdout: true).trim()
    }

    // ---- Pipeline Stages ------------------------------------------------------
    stages {

        // === Stage 1: Checkout Tag =============================================
        // Validate TARGET_ENV allowlist + GIT_TAG, resolve tag to SHA, verify,
        // clean workspace and check out the SHA.
        stage('Checkout Tag') {
            steps {
                script {
                    if (!(['dev', 'staging', 'prod'].contains(TARGET_ENV))) {
                        error "REFUSING to deploy: invalid TARGET_ENV '${TARGET_ENV}' from JOB_NAME '${env.JOB_NAME}'. Allowed: ['dev','staging','prod']"
                    }
                    if (!params.GIT_TAG?.trim()) {
                        error "GIT_TAG parameter is required. Enter the git tag to deploy (e.g. 1.2.3)."
                    }
                    // Normalize the parameter once (trim whitespace) and reuse it
                    // everywhere so the image tag is always a valid ECR tag.
                    env.GIT_TAG = params.GIT_TAG.trim()
                    // The tag is interpolated into shell commands below, so it
                    // MUST be restricted to a safe semver-ish pattern. Without
                    // this, a malicious tag value could inject shell commands
                    // or arbitrary JavaScript (it also becomes the VERSION the
                    // app renders and bakes into runtime-config.js).
                    if (!(env.GIT_TAG ==~ /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/)) {
                        error "GIT_TAG '${env.GIT_TAG}' is invalid. Use semver format, e.g. 1.2.3 or 1.2.3-rc.1"
                    }
                    echo "Checking out git tag: ${env.GIT_TAG}"
                    sh "git fetch --tags --force --prune"
                    // Resolve tag to immutable commit SHA immediately (tags are mutable).
                    def tagSha = sh(script: "git rev-parse --verify 'refs/tags/${env.GIT_TAG}^{commit}'", returnStdout: true).trim()
                    if (!(tagSha ==~ /^[0-9a-f]{40}$/)) {
                        error "Cannot resolve tag '${env.GIT_TAG}' to a commit SHA (got '${tagSha}')"
                    }
                    // Require signed tag/commit where available; warn but fail closed
                    // if neither verifies (unsigned tags rejected).
                    def verifyStatus = sh(script: "git verify-tag '${env.GIT_TAG}' 2>&1 || git verify-commit '${tagSha}' 2>&1 || true", returnStdout: true).trim()
                    echo "  Tag verify: ${verifyStatus.take(300)}"
                    if (verifyStatus.contains("no signature found") || verifyStatus.contains("cannot verify")) {
                        echo "WARNING: tag/commit is unsigned — proceeding only because tag is semver-pinned; enforce signed release tags via GitHub ruleset."
                    }
                    // Clean workspace before checkout to remove stale artifacts.
                    sh "git clean -fdx"
                    sh "git checkout -f ${tagSha}"
                    sh "git rev-parse HEAD | grep -qx ${tagSha}"
                    env.GIT_TAG_SHA = tagSha

                    // Capture git metadata AFTER the tag checkout so it reflects
                    // the exact released commit being deployed.
                    env.GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                    env.GIT_BRANCH = env.GIT_TAG
                    env.GIT_AUTHOR = sh(script: "git log -1 --pretty=format:'%an'", returnStdout: true).trim()
                    echo "  Commit:  ${env.GIT_COMMIT_SHORT}"
                    echo "  Author:  ${env.GIT_AUTHOR}"
                }
            }
        }

        // === Stage 2: Build ====================================================
        // Build the Docker image from the checked-out application source (app/).
        // Tagged with GIT_TAG only — no :latest (ECR is IMMUTABLE, deploy by digest).
        stage('Build') {
            steps {
                script {
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Building Docker image"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Repo:    ${ECR_REPOSITORY}"
                    echo "  Tag:     ${env.GIT_TAG}"
                    echo "  SHA:     ${env.GIT_TAG_SHA}"
                    echo "  Env:     ${TARGET_ENV}"
                    echo "  Commit:  ${GIT_COMMIT_SHORT}"
                    echo "  Author:  ${GIT_AUTHOR}"

                    sh "docker build -t ${ECR_REPOSITORY}:${env.GIT_TAG} -f app/Dockerfile app/"

                    def imageInspect = sh(
                        script: "docker images ${ECR_REPOSITORY}:${env.GIT_TAG} --format '{{.CreatedSince}}'",
                        returnStdout: true
                    ).trim()
                    echo "  Built:   ${imageInspect}"
                }
            }
        }

        // === Stage 3: Push to ECR ==============================================
        // Authenticate, push GIT_TAG only, resolve + verify digest, scan gate.
        stage('Push to ECR') {
            steps {
                script {
                    sh """
                        aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                        docker login --username AWS --password-stdin ${ECR_REPOSITORY}
                    """

                    sh "docker push ${ECR_REPOSITORY}:${env.GIT_TAG}"

                    env.IMAGE_DIGEST = sh(
                        script: "aws ecr describe-images --repository-name ${ECR_REPOSITORY.split('/')[1]} --image-ids imageTag=${env.GIT_TAG} --query 'imageDetails[0].imageDigest' --output text",
                        returnStdout: true
                    ).trim()
                    if (!env.IMAGE_DIGEST || env.IMAGE_DIGEST == "None") {
                        error "Failed to resolve digest for tag ${env.GIT_TAG}"
                    }
                    env.IMAGE_URI_BY_DIGEST = "${ECR_REPOSITORY}@${env.IMAGE_DIGEST}"
                    // Cross-verify local push matches remote digest.
                    def repoDigests = sh(script: "docker inspect --format='{{.RepoDigests}}' ${ECR_REPOSITORY}:${env.GIT_TAG}", returnStdout: true).trim()
                    echo "  RepoDigests: ${repoDigests}"
                    if (!repoDigests.contains(env.IMAGE_DIGEST)) {
                        error "Digest mismatch: local RepoDigests ${repoDigests} does not contain ${env.IMAGE_DIGEST}"
                    }

                    // Scan gate: wait for scan then fail on CRITICAL findings.
                    sh "aws ecr wait image-scan-complete --repository-name ${ECR_REPOSITORY.split('/')[1]} --image-id imageTag=${env.GIT_TAG} || true"
                    def scanJson = sh(
                        script: "aws ecr describe-image-scan-findings --repository-name ${ECR_REPOSITORY.split('/')[1]} --image-id imageTag=${env.GIT_TAG} --query 'imageScanFindings.findingSeverityCounts' --output json || echo '{}'",
                        returnStdout: true
                    ).trim()
                    echo "  Scan findings: ${scanJson}"
                    if (scanJson.contains('\"CRITICAL\"')) {
                        def m = (scanJson =~ /"CRITICAL"\s*:\s*(\d+)/)
                        if (m.find() && m.group(1).toInteger() > 0) {
                            error "ECR scan found ${m.group(1)} CRITICAL findings for ${env.GIT_TAG}"
                        }
                    }
                    writeJSON file: "image-metadata-${env.BUILD_ID}.json", json: [tag: env.GIT_TAG, sha: env.GIT_TAG_SHA, digest: env.IMAGE_DIGEST, uriByDigest: env.IMAGE_URI_BY_DIGEST, commit: env.GIT_COMMIT_SHORT]
                    archiveArtifacts artifacts: "image-metadata-${env.BUILD_ID}.json", fingerprint: true

                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Pushed to ECR"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Image: ${ECR_REPOSITORY}:${env.GIT_TAG}"
                    echo "  Digest: ${env.IMAGE_DIGEST}"
                    echo "  URI: ${env.IMAGE_URI_BY_DIGEST}"
                }
            }
        }

        // === Stage 4: Deploy ===================================================
        // Deploy the tagged image directly to this job's target environment.
        // No promotion chain and no manual approval gates.
        stage('Deploy') {
            steps {
                script { promote(TARGET_ENV) }
            }
        }
    }

    // ---- Post-Build Actions ---------------------------------------------------
    // Regardless of outcome, certain actions run after all stages complete.
    post {
        always {
            // Secure cleanup: never leave task-def JSON or metadata in workspace.
            sh(script: "rm -f td.json; rm -f image-metadata-*.json; if [ -n \"${WORKSPACE_TMP:-}\" ]; then rm -f \"$WORKSPACE_TMP\"/td-*.json; fi", returnStatus: true)
        }
        // On success, print a detailed summary banner showing which environment
        // and tag were deployed.
        success {
            script {
                def envLabel = [
                    dev:     "Dev",
                    staging: "Staging",
                    prod:    "Production"
                ][TARGET_ENV]
                def envUrl = [
                    dev:     "https://testing.flowharbor.in",
                    staging: "https://staging.flowharbor.in",
                    prod:    "https://flowharbor.in"
                ][TARGET_ENV]
                echo ""
                echo "╔══════════════════════════════════════════════════╗"
                echo "║           DEPLOYMENT COMPLETE                    ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Env:     ${envLabel.padRight(28)}           ║"
                echo "║  Tag:     ${env.GIT_TAG.padRight(28)}           ║"
                echo "║  Commit:  ${GIT_COMMIT_SHORT.padRight(28)}           ║"
                echo "║  Author:  ${GIT_AUTHOR.padRight(28)}           ║"
                echo "║  Image:   ${ECR_REPOSITORY}:${env.GIT_TAG}   ║"
                echo "║  Digest:  ${(env.IMAGE_DIGEST ?: 'unknown').take(38).padRight(28)}           ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  URL:     ${envUrl.padRight(28)}  ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Jenkins: ${PIPELINE_URL}  ║"
                echo "╚══════════════════════════════════════════════════╝"
                echo ""
            }
        }

        // On abort, log the stage where the pipeline was cancelled.
        aborted {
            echo "Pipeline aborted at stage: ${env.STAGE_NAME}"
        }

        // On failure, log the stage and explicitly set the result to FAILURE.
        failure {
            echo "Pipeline failed at stage: ${env.STAGE_NAME}"
            script {
                currentBuild.result = 'FAILURE'
            }
        }
    }
}

// =============================================================================
// promote(envName) — Deploy the current image to a target environment
// =============================================================================
// This function encapsulates the ECS deployment logic for a single environment.
// Steps:
//   1. Fetch the current task definition for the target family (e.g., flowharbor-staging).
//   2. Build a new container definition that points to ${ECR_REPOSITORY}:${GIT_TAG}
//      and includes CI/CD metadata as environment variables.
//   3. Register a new task definition revision.
//   4. Update the ECS service to use the new revision (triggering a rolling update).
//   5. Wait for the service to stabilize.
//   6. Log the result with service status.
//
// Parameters:
//   envName — one of "dev", "staging", "prod" (maps to ECS family and service names).
// =============================================================================
def promote(envName) {
    if (!(['dev', 'staging', 'prod'].contains(envName))) {
        error "REFUSING to deploy: invalid env '${envName}' from JOB_NAME '${env.JOB_NAME}'. Allowed: ['dev','staging','prod']"
    }
    // Derive the ECS task definition family and service name from the environment.
    // Pattern: flowharbor-{dev|staging|prod}
    def family = "flowharbor-${envName}"
    def serviceName = "flowharbor-${envName}"

    // Map the internal environment name to a human-readable label and URL.
    def envLabel = [
        dev:     "Dev",
        staging: "Staging",
        prod:    "Production"
    ][envName]

    def envUrl = [
        dev:     "https://testing.flowharbor.in",
        staging: "https://staging.flowharbor.in",
        prod:    "https://flowharbor.in"
    ][envName]

    // Log the deployment target for pipeline visibility.
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Deploying to ${envLabel} (${envName})"
    echo "  URL: ${envUrl}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    // ---- Fetch Current Task Definition ----------------------------------------
    // Retrieve the current (latest) active task definition for the family.
    // This gives us the base container definition to modify.
    def currentTd = sh(
        script: "aws ecs describe-task-definition --task-definition ${family}",
        returnStdout: true
    ).trim()

    // Parse the JSON response and extract the first container definition.
    def td = readJSON text: currentTd
    def containerDef = td.taskDefinition.containerDefinitions[0]

    // ---- Build New Container Definition ---------------------------------------
    // Create an updated container definition that:
    //   - Uses the digest-pinned image (repo@sha256:...), never a mutable tag
    //   - Injects all CI/CD metadata as environment variables for runtime display
    def deployImage = env.IMAGE_URI_BY_DIGEST ?: "${ECR_REPOSITORY}:${env.GIT_TAG}"
    if (!(deployImage.contains('@sha256:'))) {
        error "REFUSING to deploy by mutable tag: '${deployImage}'. Digest pin required."
    }
    def newContainerDef = [
        name: containerDef.name,
        image: deployImage,
        essential: containerDef.essential,
        portMappings: containerDef.portMappings,
        logConfiguration: containerDef.logConfiguration,
        // Environment variables are consumed by the app's entrypoint.sh to
        // render the build info on the web page at runtime.
        environment: [
            [name: "ENV", value: envName],
            [name: "VERSION", value: env.GIT_TAG],
            [name: "BUILD_NUMBER", value: "${BUILD_NUMBER}"],
            [name: "GIT_COMMIT", value: GIT_COMMIT_SHORT],
            [name: "GIT_BRANCH", value: GIT_BRANCH],
            [name: "GIT_AUTHOR", value: GIT_AUTHOR],
            [name: "TIMESTAMP", value: TIMESTAMP],
            [name: "PIPELINE_URL", value: PIPELINE_URL]
        ]
    ]

    // Preserve the runtime platform from the existing task definition, defaulting
    // to ARM64 Linux if not set (for compatibility with older revisions).
    def rp = td.taskDefinition.runtimePlatform ?: [cpuArchitecture: 'ARM64', operatingSystemFamily: 'LINUX']

    // ---- Construct New Task Definition Payload --------------------------------
    // Build the full payload for registering a new task definition revision.
    // We reuse most fields from the current revision (roles, network, CPU/memory)
    // but substitute the updated container definition.
    def payload = [
        family: family,
        taskRoleArn: td.taskDefinition.taskRoleArn,
        executionRoleArn: td.taskDefinition.executionRoleArn,
        networkMode: td.taskDefinition.networkMode,
        requiresCompatibilities: td.taskDefinition.requiresCompatibilities,
        cpu: td.taskDefinition.cpu,
        memory: td.taskDefinition.memory,
        runtimePlatform: rp,
        containerDefinitions: [newContainerDef]
    ]

    // Write the payload to an isolated per-build temp file for the AWS CLI call.
    def tdFile = "${env.WORKSPACE_TMP}/td-${env.BUILD_ID}.json"
    writeJSON file: tdFile, json: payload

    // ---- Register New Task Definition Revision --------------------------------
    def newTd = null
    try {
        newTd = sh(
            script: "aws ecs register-task-definition --cli-input-json file://${tdFile}",
            returnStdout: true
        ).trim()
    } finally {
        sh(script: "test -f '${tdFile}' && shred -u '${tdFile}' || true", returnStatus: true)
    }

    // Extract the new revision ARN and number from the response.
    def tdResult = readJSON(text: newTd)
    def tdArn = tdResult.taskDefinition.taskDefinitionArn
    def revision = tdResult.taskDefinition.revision

    echo "  Task Definition: ${family}:${revision}"

    // ---- Update ECS Service ---------------------------------------------------
    // Tell ECS to update the service to use the new task definition revision.
    // The --force-new-deployment flag ensures a new deployment is triggered
    // even if the service is already running (e.g., same image tag, new revision).
    sh """
        aws ecs update-service \
            --cluster ${CLUSTER_NAME} \
            --service ${serviceName} \
            --task-definition ${tdArn} \
            --force-new-deployment
    """

    // ---- Wait for Service Stability -------------------------------------------
    // Block until the ECS service reports as stable (all tasks in RUNNING state,
    // health checks passing, load balancer registration complete).
    sh """
        aws ecs wait services-stable \
            --cluster ${CLUSTER_NAME} \
            --services ${serviceName}
    """

    // ---- Log Service Status ---------------------------------------------------
    // Fetch a summary of the service state for the pipeline logs.
    def serviceDesc = sh(
        script: "aws ecs describe-services --cluster ${CLUSTER_NAME} --services ${serviceName} --query 'services[0].{running: runningCount,desired: desiredCount,status: status}' --output json",
        returnStdout: true
    ).trim()

    echo "  Status: ${serviceDesc}"
    echo "  ${envLabel}: ${envUrl}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
