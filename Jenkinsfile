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
//   1. Checkout Tag — fetch all tags and check out the requested GIT_TAG so the
//      app source matches the exact released commit (Jenkinsfile is loaded from main).
//   2. Build         — Docker image build, tagged with GIT_TAG and :latest
//   3. Push to ECR   — Authenticate with ECR, push both tags, log the digest
//   4. Deploy        — Register a new ECS task definition revision pinned to the
//                      GIT_TAG image and trigger a rolling update on this job's env.
//
// On success, a summary banner with the deployed environment and tag is printed.
//
// The `promote()` function encapsulates the logic for registering a new ECS
// task definition revision and triggering a rolling service update.
// =============================================================================

// ---- Pipeline Definition ----------------------------------------------------
pipeline {
    agent { label 'jenkins-slave' }

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
        // Validate the GIT_TAG parameter, fetch all tags from the remote, and
        // check out the requested tag so the app source matches the release.
        // The Jenkinsfile itself is loaded from the main branch (job SCM config).
        stage('Checkout Tag') {
            steps {
                script {
                    if (!params.GIT_TAG?.trim()) {
                        error "GIT_TAG parameter is required. Enter the git tag to deploy (e.g. 1.2.3)."
                    }
                    echo "Checking out git tag: ${params.GIT_TAG}"
                    sh "git fetch --tags --force --prune"
                    sh "git checkout -f ${params.GIT_TAG}"

                    // Capture git metadata AFTER the tag checkout so it reflects
                    // the exact released commit being deployed.
                    env.GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                    env.GIT_BRANCH = params.GIT_TAG
                    env.GIT_AUTHOR = sh(script: "git log -1 --pretty=format:'%an'", returnStdout: true).trim()
                    echo "  Commit:  ${env.GIT_COMMIT_SHORT}"
                    echo "  Author:  ${env.GIT_AUTHOR}"
                }
            }
        }

        // === Stage 2: Build ====================================================
        // Build the Docker image from the checked-out application source (app/).
        // The image is tagged with the git tag and "latest".
        stage('Build') {
            steps {
                script {
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Building Docker image"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Repo:    ${ECR_REPOSITORY}"
                    echo "  Tag:     ${params.GIT_TAG}"
                    echo "  Env:     ${TARGET_ENV}"
                    echo "  Commit:  ${GIT_COMMIT_SHORT}"
                    echo "  Author:  ${GIT_AUTHOR}"

                    sh "docker build -t ${ECR_REPOSITORY}:${params.GIT_TAG} -f app/Dockerfile app/"

                    sh "docker tag ${ECR_REPOSITORY}:${params.GIT_TAG} ${ECR_REPOSITORY}:latest"

                    def imageInspect = sh(
                        script: "docker images ${ECR_REPOSITORY}:${params.GIT_TAG} --format '{{.CreatedSince}}'",
                        returnStdout: true
                    ).trim()
                    echo "  Built:   ${imageInspect}"
                }
            }
        }

        // === Stage 3: Push to ECR ==============================================
        // Authenticate Docker with the AWS ECR registry, then push both tags
        // (git tag and latest). The image digest is retrieved for auditing.
        stage('Push to ECR') {
            steps {
                script {
                    sh """
                        aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                        docker login --username AWS --password-stdin ${ECR_REPOSITORY}
                    """

                    sh "docker push ${ECR_REPOSITORY}:${params.GIT_TAG}"
                    sh "docker push ${ECR_REPOSITORY}:latest"

                    def digest = sh(
                        script: "aws ecr describe-images --repository-name ${ECR_REPOSITORY.split('/')[1]} --image-ids imageTag=${params.GIT_TAG} --query 'imageDetails[0].imageDigest' --output text",
                        returnStdout: true
                    ).trim()

                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Pushed to ECR"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Image: ${ECR_REPOSITORY}:${params.GIT_TAG}"
                    echo "  Digest: ${digest}"
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
                echo "║  Tag:     ${params.GIT_TAG.padRight(28)}           ║"
                echo "║  Commit:  ${GIT_COMMIT_SHORT.padRight(28)}           ║"
                echo "║  Author:  ${GIT_AUTHOR.padRight(28)}           ║"
                echo "║  Image:   ${ECR_REPOSITORY}:${params.GIT_TAG}   ║"
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
    //   - Uses the git-tag image (just pushed in the ECR stage)
    //   - Injects all CI/CD metadata as environment variables for runtime display
    def newContainerDef = [
        name: containerDef.name,
        image: "${ECR_REPOSITORY}:${params.GIT_TAG}",
        essential: containerDef.essential,
        portMappings: containerDef.portMappings,
        logConfiguration: containerDef.logConfiguration,
        // Environment variables are consumed by the app's entrypoint.sh to
        // render the build info on the web page at runtime.
        environment: [
            [name: "ENV", value: envName],
            [name: "VERSION", value: params.GIT_TAG],
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

    // Write the payload to a temp file for the AWS CLI call.
    writeJSON file: 'td.json', json: payload

    // ---- Register New Task Definition Revision --------------------------------
    def newTd = sh(
        script: "aws ecs register-task-definition --cli-input-json file://td.json",
        returnStdout: true
    ).trim()

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
